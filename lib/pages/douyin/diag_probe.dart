import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/pages/douyin/rootscan.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 全量诊断开关。
///
/// 默认开启。历史上多次出现「构建时忘了传 --dart-define → 证据一条没写 →
/// 又白测一轮」的坑，所以这里反转为默认 ON：除非显式传
/// `--dart-define=PILIPLUS_DIAG_OFF=true`，否则采样、切条探针与导出入口全部生效。
/// 诊断阶段结束后再改成默认关闭。
const bool kDiagEnabled = !bool.fromEnvironment('PILIPLUS_DIAG_OFF');

/// mpv 解码/渲染侧需要入证的指标。读不到就记 null，不抛错。
const List<String> kMpvDiagKeys = <String>[
  'hwdec-current',
  'video-codec',
  'video-params/w',
  'video-params/h',
  'video-params/pixfmt',
  'estimated-vf-fps',
  'drop-frame-count',
  'vo-drop-frame-count',
  'decoder-frame-drop-count',
  'cache-speed',
  'demuxer-cache-time',
];

const String kDiagPlaybackFile = 'diag_playback.log';

/// PiP 轻量模式的持久化 key。放在 diag_probe 里是因为它属于诊断 A/B 开关，
/// 不额外扩展全局设置键表。
const String _kPipLiteModeKey = 'douyinPipLiteMode';

/// 起播 3 秒后仍 position>0，才开始判断是否黑屏嫌疑。
const int _blackScreenCheckMs = 3000;

/// 一次切条最多观察 8 秒，避免探针永远挂着。
const int _openProbeTimeoutMs = 8000;

/// 3 秒内丢帧增量达到这个值，视为「暴涨」。
const int _dropFrameJumpThreshold = 30;

/// 播放过程与切条的一次性取证。
///
/// 所有写入都是「尽力而为」：路径拿不到、文件写不了、mpv 属性不支持，
/// 一律吞掉。诊断代码绝不能反过来影响播放。
abstract final class DiagProbe {
  static const MethodChannel _channel = MethodChannel(
    'piliplus/diag_export',
  );

  static Timer? _sampleTimer;
  static Timer? _openTimer;
  static _OpenTracker? _tracker;
  static Future<void> _writeChain = Future<void>.value();
  static Future<Directory>? _documentsDir;

  static Future<Directory> _docDir() =>
      _documentsDir ??= getApplicationDocumentsDirectory();

  /// 诊断：PiP 轻量模式。默认开启；关闭后回到源分辨率渲染路径，便于 A/B。
  static bool get pipLiteMode {
    try {
      return GStorage.setting.get(_kPipLiteModeKey, defaultValue: true);
    } catch (_) {
      return true;
    }
  }

  static Future<void> setPipLiteMode(bool value) async {
    try {
      await GStorage.setting.put(_kPipLiteModeKey, value);
    } catch (_) {}
  }

  /// 一次读取当前播放器的 mpv 指标、position 与 textureId。
  ///
  /// rootscan 也直接复用这个快照，保证两处字段完全一致。
  static Map<String, Object?> snapshot() {
    final out = <String, Object?>{
      'positionMs': null,
      'textureId': null,
      'dataStatus': null,
    };
    PlPlayerController? player;
    try {
      player = PlPlayerController.instance;
    } catch (_) {}
    if (player == null) {
      for (final key in kMpvDiagKeys) {
        out[key] = null;
      }
      return out;
    }
    try {
      out['positionMs'] = player.positionInMilliseconds;
      out['textureId'] = player.videoController?.id.value;
      out['dataStatus'] = player.dataStatus.value.name;
    } catch (_) {}
    final native = player.videoPlayerController;
    for (final key in kMpvDiagKeys) {
      String? value;
      try {
        final raw = native?.getProperty(key);
        if (raw != null && raw.isNotEmpty) value = raw;
      } catch (_) {}
      out[key] = value;
    }
    return out;
  }

  /// App 版本 / 构建号 / 系统 / 机型。
  ///
  /// iOS 的真实值由 AppDelegate 从 mainBundle 与 uname 读出；通道缺失时
  /// 用 package_info_plus 兜底，至少保证 rootscan.json 里有版本号。
  static Future<Map<String, Object?>> appInfo() async {
    final out = <String, Object?>{};
    try {
      final info = await _channel
          .invokeMapMethod<String, Object?>('appInfo')
          .timeout(const Duration(seconds: 2));
      if (info != null) out.addAll(info);
    } catch (_) {}
    if ((out['version'] as String?)?.isNotEmpty != true) {
      try {
        final package = await PackageInfo.fromPlatform();
        out['version'] = package.version;
        out['build'] = package.buildNumber;
      } catch (_) {}
    }
    if (out['systemVersion'] == null) {
      try {
        out['systemVersion'] = Platform.operatingSystemVersion;
      } catch (_) {}
    }
    return out;
  }

  /// 播放期间每秒一行 JSONL。诊断包常开，普通包直接 return。
  static void startSampling() {
    if (!kDiagEnabled) return;
    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _append('playback', snapshot());
    });
  }

  static void stopSampling() {
    if (!kDiagEnabled) return;
    _sampleTimer?.cancel();
    _sampleTimer = null;
  }

  /// 写一条 `diag_event`，用于记录 Dart 主 isolate 的卡顿等一次性事件。
  static void event(String event, [Map<String, Object?> fields = const {}]) {
    if (!kDiagEnabled) return;
    _append('diag_event', <String, Object?>{'event': event, ...fields});
  }

  /// 记录一次 [_open] 的起点。旧 textureId 由调用方在 setDataSource 前读取。
  static void beginOpen({
    required int index,
    required String key,
    int? oldTextureId,
  }) {
    if (!kDiagEnabled) return;
    _stopOpenProbe();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final snap = snapshot();
    final tracker = _OpenTracker(
      index: index,
      key: key,
      startedAt: startedAt,
      oldTextureId: oldTextureId,
      startPositionMs: _asInt(snap['positionMs']),
      dropBaseline: _asInt(snap['drop-frame-count']),
    );
    _tracker = tracker;
    _append('open-start', <String, Object?>{
      'index': index,
      'key': key,
      'oldTextureId': oldTextureId,
      'positionMs': snap['positionMs'],
      'dataStatus': snap['dataStatus'],
    });
    _openTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _pollOpen(),
    );
  }

  /// [_open] 收尾时写一行汇总。出错时同时停掉探针，避免误记到下一条。
  static void endOpen({String? error}) {
    if (!kDiagEnabled) return;
    final tracker = _tracker;
    if (tracker == null || tracker.ended) return;
    tracker.ended = true;
    final snap = snapshot();
    final now = DateTime.now().millisecondsSinceEpoch;
    _append('open-end', <String, Object?>{
      'index': tracker.index,
      'key': tracker.key,
      'error': error,
      'elapsedMs': now - tracker.startedAt,
      'oldTextureId': tracker.oldTextureId,
      'newTextureId': tracker.newTextureId ?? snap['textureId'],
      'loadedAfterMs': tracker.loadedAt == null
          ? null
          : tracker.loadedAt! - tracker.startedAt,
      'firstFrameAfterMs': tracker.firstFrameAt == null
          ? null
          : tracker.firstFrameAt! - tracker.startedAt,
      'positionMs': snap['positionMs'],
      'dataStatus': snap['dataStatus'],
    });
    if (error != null) {
      _append('diag_event', <String, Object?>{
        'event': 'open-failed',
        'index': tracker.index,
        'error': error,
      });
      _stopOpenProbe();
    }
  }

  /// 页面退出时统一收尾。
  static void stop() {
    if (!kDiagEnabled) return;
    stopSampling();
    _stopOpenProbe();
  }

  /// 把 Documents 下的诊断文件打成一个 zip，并交给系统分享面板。
  ///
  /// 缺失的文件直接跳过；没有任何文件或打包失败返回 null，不弹异常。
  static Future<String?> exportAndShare() async {
    if (!kDiagEnabled) return null;
    File? zipFile;
    try {
      final dir = await _docDir();
      final files = <File>[];
      for (final name in <String>[
        'pip_trace.log',
        kDiagPlaybackFile,
        PiliRootScan.fileName,
        'ui_hierarchy.txt',
      ]) {
        final file = File('${dir.path}/$name');
        if (!file.existsSync() || file.lengthSync() == 0) continue;
        files.add(file);
      }
      if (files.isEmpty) return null;
      zipFile = File('${dir.path}/diag_${_timestamp()}.zip');
      final out = OutputFileStream(zipFile.path);
      final encoder = ZipEncoder();
      try {
        encoder.startEncode(out);
        for (final file in files) {
          encoder.add(
            ArchiveFile.stream(
              file.uri.pathSegments.last,
              InputFileStream(file.path),
            ),
          );
        }
        encoder.endEncode();
      } finally {
        out.close();
      }
      try {
        await _channel.invokeMethod<bool>('shareFile', <String, Object?>{
          'path': zipFile.path,
        });
      } catch (_) {}
      return zipFile.path;
    } catch (_) {
      if (zipFile != null) {
        try {
          if (zipFile.existsSync()) zipFile.deleteSync();
        } catch (_) {}
      }
      return null;
    }
  }

  static void _pollOpen() {
    if (!kDiagEnabled) return;
    final tracker = _tracker;
    if (tracker == null) {
      _stopOpenProbe();
      return;
    }
    try {
      final player = PlPlayerController.instance;
      if (player == null) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final position = player.positionInMilliseconds;
      final textureId = player.videoController?.id.value;
      if (textureId != null) tracker.newTextureId = textureId;
      final status = player.dataStatus.value;
      if (status == DataStatus.loading) tracker.sawLoading = true;
      // 切条刚开始时 position 还是上一条的，不能直接当新视频首帧。
      // 纹理换了，或位置已经回到起播区间，才认为新视频真的出画面了。
      final textureChanged =
          textureId != null &&
          tracker.oldTextureId != null &&
          textureId != tracker.oldTextureId;
      final positionReset =
          tracker.startPositionMs != null
          ? position < tracker.startPositionMs! || position <= 1200
          : position <= 1200;
      final loadedWindow =
          tracker.sawLoading ||
          tracker.oldTextureId == null ||
          textureChanged ||
          positionReset;
      if (tracker.loadedAt == null &&
          status == DataStatus.loaded &&
          loadedWindow) {
        tracker.loadedAt = now;
        _append('open-loaded', <String, Object?>{
          'index': tracker.index,
          'textureId': textureId,
          'afterOpenMs': now - tracker.startedAt,
        });
      }
      final newVideoWindow =
          tracker.oldTextureId == null || textureChanged || positionReset;
      if (tracker.firstFrameAt == null && position > 0 && newVideoWindow) {
        tracker.firstFrameAt = now;
        // 丢帧基线改在首帧时采，避免拿上一条的累计丢帧数算增量。
        tracker.dropBaseline = _asInt(snapshot()['drop-frame-count']);
        _append('open-first-frame', <String, Object?>{
          'index': tracker.index,
          'textureId': textureId,
          'positionMs': position,
          'afterOpenMs': now - tracker.startedAt,
          'afterLoadedMs': tracker.loadedAt == null
              ? null
              : now - tracker.loadedAt!,
        });
      }
      final elapsed = now - tracker.startedAt;
      final checkFrom = tracker.firstFrameAt ?? tracker.startedAt;
      if (!tracker.blackChecked &&
          now - checkFrom >= _blackScreenCheckMs &&
          position > 0) {
        tracker.blackChecked = true;
        _checkBlackScreen(tracker, position, elapsed);
      }
      if (elapsed >= _openProbeTimeoutMs) {
        if (tracker.firstFrameAt == null) {
          _append('diag_event', <String, Object?>{
            'event': 'open-no-first-frame',
            'index': tracker.index,
            'elapsedMs': elapsed,
          });
        }
        _stopOpenProbe();
      }
    } catch (_) {}
  }

  static void _checkBlackScreen(
    _OpenTracker tracker,
    int position,
    int elapsed,
  ) {
    final snap = snapshot();
    final width = _asNum(snap['video-params/w']);
    final drop = _asNum(snap['drop-frame-count']);
    final delta = drop != null && tracker.dropBaseline != null
        ? drop - tracker.dropBaseline!
        : null;
    String? reason;
    if (width == null) {
      reason = 'video-params/w-null';
    } else if (delta != null && delta >= _dropFrameJumpThreshold) {
      reason = 'drop-frame-count-jump';
    }
    if (reason == null) return;
    _append('diag_event', <String, Object?>{
      'event': 'blackscreen-suspect',
      'reason': reason,
      'index': tracker.index,
      'key': tracker.key,
      'elapsedMs': elapsed,
      'positionMs': position,
      'videoParamsW': snap['video-params/w'],
      'videoParamsH': snap['video-params/h'],
      'pixfmt': snap['video-params/pixfmt'],
      'videoCodec': snap['video-codec'],
      'hwdec': snap['hwdec-current'],
      'dropFrameBase': tracker.dropBaseline,
      'dropFrameNow': drop,
      'dropFrameDelta': delta,
      'textureId': tracker.newTextureId ?? snap['textureId'],
    });
  }

  static void _stopOpenProbe() {
    _openTimer?.cancel();
    _openTimer = null;
    _tracker = null;
  }

  static void _append(String tag, Map<String, Object?> fields) {
    if (!kDiagEnabled) return;
    final line = jsonEncode(<String, Object?>{
      't': DateTime.now().millisecondsSinceEpoch,
      'tag': tag,
      ...fields,
    });
    _writeChain = _writeChain.then((_) => _writeLine(line));
  }

  static Future<void> _writeLine(String line) async {
    try {
      final dir = await _docDir();
      await File('${dir.path}/$kDiagPlaybackFile').writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  static num? _asNum(Object? value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  static int? _asInt(Object? value) => _asNum(value)?.toInt();

  static String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}

final class _OpenTracker {
  _OpenTracker({
    required this.index,
    required this.key,
    required this.startedAt,
    required this.oldTextureId,
    required this.startPositionMs,
    required this.dropBaseline,
  });

  final int index;
  final String key;
  final int startedAt;
  final int? oldTextureId;
  final int? startPositionMs;
  int? dropBaseline;

  int? newTextureId;
  int? loadedAt;
  int? firstFrameAt;
  bool sawLoading = false;
  bool blackChecked = false;
  bool ended = false;
}
