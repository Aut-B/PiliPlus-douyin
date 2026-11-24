import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

/// 一次 open 超过 5 秒还没收尾，写一条 `open-stuck` 留证。
const int _openStuckMs = 5000;

/// 切条探针前 3 秒用 100ms 轮询抓首帧，之后降到 500ms。
///
/// 整段 8 秒都按 100ms 轮询时，探针本身每秒要读几十次播放器状态；一旦
/// mpv 核心在打开/seek 期间占着锁，这些同步读取就会把主 isolate 一起拖住。
const int _openFastWindowMs = 3000;
const int _openFastPollMs = 100;
const int _openSlowPollMs = 500;

/// 单段同步工作超过这个值就写一条 `ui-block`，供下一份诊断包定位。
const int _uiBlockMs = 50;

/// mpv 属性每 3 秒完整刷新一次，其余采样复用缓存。
const int _mpvSnapshotIntervalMs = 3000;

/// 诊断日志批量落盘：攒够行数或等 500ms 再写，不再每行 flush。
const int _writeBatchLines = 32;
const int _writeFlushDelayMs = 500;

/// diag_playback.log 单文件上限。超过后只保留末尾约一半，避免常开诊断
/// 把 Documents 撑到几十 MB。
const int _maxPlaybackLogBytes = 8 * 1024 * 1024;
const int _playbackLogKeepBytes = _maxPlaybackLogBytes ~/ 2;

/// ticker-gap 只有超过 3 倍上报间隔（500ms × 3）才算真实停顿。
/// 调用方按 500ms 节拍上报，阈值放在写入口统一过滤，避免每秒一条噪声。
const int _tickerGapThresholdMs = 1500;

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
  static Timer? _writeFlushTimer;
  static bool _openSlowPoll = false;
  static _OpenTracker? _tracker;
  static Future<void> _writeChain = Future<void>.value();
  static Future<Directory>? _documentsDir;
  static final List<String> _writeBuffer = <String>[];
  static int _writeBatchCount = 0;

  /// 已落盘的 diag_playback.log 字节数；-1 表示尚未探测。
  static int _playbackBytes = -1;

  /// 本页会话内的 open 序号与按来源统计。`stop()` 时汇总成
  /// `session-summary`，用来直接对比自动连播与手动选播。
  static int _openSeq = 0;
  static int _sessionStartedAt = 0;
  static int _sessionBlackCount = 0;
  static final Set<int> _sessionTextureIds = <int>{};
  static final Map<String, int> _sessionOpenBySource = <String, int>{};
  static final Map<String, int> _sessionBlackBySource = <String, int>{};

  /// 最近一次 App 回到前台的时间，以及「回前台后首个请求」的待消费标记。
  ///
  /// 网络失败取证需要知道失败请求离最近一次 resume 有多久、是不是 resume
  /// 后的第一个请求；状态只在这里保存，http/mobile_observer 只读调用。
  static int _lastResumeAtMs = 0;
  static bool _awaitFirstRequestAfterResume = false;
  static bool _lastResumeWasLongIdle = false;

  /// 上一次完整读取 mpv 属性的时间与结果。
  static int _mpvCacheAt = 0;
  static final Map<String, Object?> _mpvCache = <String, Object?>{};

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

  /// 页面会话起点。进入播放页时调用一次；[stop] 时写 `session-summary`。
  static void startSession() {
    if (!kDiagEnabled) return;
    _sessionStartedAt = DateTime.now().millisecondsSinceEpoch;
    _openSeq = 0;
    _sessionBlackCount = 0;
    _sessionTextureIds.clear();
    _sessionOpenBySource.clear();
    _sessionBlackBySource.clear();
  }

  /// 本页从进入到现在经过的毫秒数；未开会话时返回 0。
  static int get sessionElapsedMs => _sessionStartedAt == 0
      ? 0
      : DateTime.now().millisecondsSinceEpoch - _sessionStartedAt;

  /// 一次读取当前播放器的 mpv 指标、position 与 textureId。
  ///
  /// rootscan 也直接复用这个快照，保证两处字段完全一致。
  static Map<String, Object?> snapshot({bool full = false}) {
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

    // `getProperty` 是同步 FFI 调用，mpv 核心忙时会阻塞调用线程。每次
    // 读 11 项看起来不多，但叠上切条/seek 时的锁竞争就足以把主 isolate
    // 卡成秒级。这里只降频，不删指标：完整快照最多 3 秒一次。
    final now = DateTime.now().millisecondsSinceEpoch;
    final refresh =
        full ||
        _mpvCache.isEmpty ||
        now - _mpvCacheAt >= _mpvSnapshotIntervalMs;
    if (refresh) {
      final native = player.videoPlayerController;
      for (final key in kMpvDiagKeys) {
        String? value;
        try {
          final raw = native?.getProperty(key);
          if (raw != null && raw.isNotEmpty) value = raw;
        } catch (_) {}
        _mpvCache[key] = value;
      }
      _mpvCacheAt = now;
    }
    for (final key in kMpvDiagKeys) {
      out[key] = _mpvCache[key];
    }
    return out;
  }

  /// 切条前后 mpv 状态会整体换掉，缓存必须作废，否则新视频的宽高/解码
  /// 指标要等到下一次完整刷新才更新。
  static void invalidateSnapshotCache() {
    _mpvCache.clear();
    _mpvCacheAt = 0;
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

  /// 播放期间每 2 秒一行 JSONL。诊断包常开，普通包直接 return。
  ///
  /// 采样会同步读 mpv 属性，降到 2 秒一次可明显减少主 isolate 的 FFI 读取。
  static void startSampling() {
    if (!kDiagEnabled) return;
    _sampleTimer?.cancel();
    _sampleTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final sw = Stopwatch()..start();
      _append('playback', snapshot());
      _eventIfSlow('snapshot', sw);
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
    // ticker-gap 由 500ms 定时器逐拍上报；这里统一按 3 倍间隔过滤，
    // 只在真正停顿时留证，避免单类事件刷出几万条。
    if (event == 'ticker-gap') {
      final gapMs = _asInt(fields['gapMs']);
      if (gapMs == null || gapMs <= _tickerGapThresholdMs) return;
    }
    _append('diag_event', <String, Object?>{'event': event, ...fields});
  }

  /// 通用只读诊断入口，与播放诊断共用同一份 diag_playback.log。
  ///
  /// 生命周期与网络失败取证都走这里，避免再开一条写入链路导致行交错。
  static void log(String tag, Map<String, Object?> fields) {
    if (!kDiagEnabled) return;
    _append(tag, fields);
  }

  /// App 回到前台时登记一次 resume，供网络失败取证计算 msSinceResume /
  /// firstAfterResume；不参与任何网络决策。
  static void noteResume(int atMs, {required bool longIdle}) {
    if (!kDiagEnabled) return;
    _lastResumeAtMs = atMs;
    _awaitFirstRequestAfterResume = true;
    _lastResumeWasLongIdle = longIdle;
  }

  /// 每个请求开始时调用一次，返回
  /// (msSinceResume, firstAfterResume, firstAfterLongIdle)。
  /// 首个请求会消费掉「回前台」标记，后面的请求只保留时间差。
  static (int?, bool, bool) takeRequestTiming() {
    if (!kDiagEnabled) {
      return (null, false, false);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final msSinceResume = _lastResumeAtMs == 0 ? null : now - _lastResumeAtMs;
    final first = _awaitFirstRequestAfterResume;
    final firstAfterLongIdle = first && _lastResumeWasLongIdle;
    _awaitFirstRequestAfterResume = false;
    return (msSinceResume, first, firstAfterLongIdle);
  }

  /// 记录一次 [_open] 的起点。旧 textureId 由调用方在 setDataSource 前读取。
  static void beginOpen({
    required int index,
    required String key,
    int? oldTextureId,
    String source = 'auto',
  }) {
    if (!kDiagEnabled) return;
    final sw = Stopwatch()..start();
    _stopOpenProbe();
    invalidateSnapshotCache();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final snap = snapshot(full: true);
    final seq = ++_openSeq;
    if (oldTextureId != null) _sessionTextureIds.add(oldTextureId);
    _sessionOpenBySource[source] = (_sessionOpenBySource[source] ?? 0) + 1;
    final tracker = _OpenTracker(
      seq: seq,
      source: source,
      index: index,
      key: key,
      startedAt: startedAt,
      oldTextureId: oldTextureId,
      startPositionMs: _asInt(snap['positionMs']),
      dropBaseline: _asInt(snap['drop-frame-count']),
    );
    _tracker = tracker;
    _append('open-start', <String, Object?>{
      'seq': seq,
      'source': source,
      'index': index,
      'key': key,
      'oldTextureId': oldTextureId,
      'positionMs': snap['positionMs'],
      'dataStatus': snap['dataStatus'],
    });
    _passiveUiBlock('beginOpen', sw);
    _rearmOpenTimer(_openFastPollMs);
  }

  /// 记录当前 open 进行到哪一段，供 `open-stuck` 判断卡在哪一步。
  static void openPhase(String phase) {
    if (!kDiagEnabled) return;
    _tracker?.phase = phase;
  }

  /// [_open] 收尾时写一行汇总。出错时同时停掉探针，避免误记到下一条。
  static void endOpen({String? error}) {
    if (!kDiagEnabled) return;
    final tracker = _tracker;
    if (tracker == null || tracker.ended) return;
    final sw = Stopwatch()..start();
    tracker.ended = true;
    invalidateSnapshotCache();
    // 缓存刚被作废，默认快照会自己刷新一次；不再强制 full，避免多读一轮。
    final snap = snapshot();
    final now = DateTime.now().millisecondsSinceEpoch;
    final newTextureId = _asInt(tracker.newTextureId ?? snap['textureId']);
    if (newTextureId != null) _sessionTextureIds.add(newTextureId);
    final elapsedMs = now - tracker.startedAt;
    _append('open-seq', <String, Object?>{
      'seq': tracker.seq,
      'source': tracker.source,
      'index': tracker.index,
      'key': tracker.key,
      'oldTextureId': tracker.oldTextureId,
      'newTextureId': newTextureId,
      'textureChanged': tracker.oldTextureId == null || newTextureId == null
          ? null
          : tracker.oldTextureId != newTextureId,
      'distinctTextureCount': _sessionTextureIds.length,
      'elapsedMs': elapsedMs,
      'error': error,
    });
    _append('open-end', <String, Object?>{
      'seq': tracker.seq,
      'source': tracker.source,
      'index': tracker.index,
      'key': tracker.key,
      'error': error,
      'elapsedMs': elapsedMs,
      'oldTextureId': tracker.oldTextureId,
      'newTextureId': newTextureId,
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
    _passiveUiBlock('endOpen', sw);
  }

  /// 一条视频真正起播时写一行，标出它是否已经出现过首帧缺失。
  static void playItem({required String key, String? source}) {
    if (!kDiagEnabled) return;
    final tracker = _tracker;
    _append('play-item', <String, Object?>{
      'seq': tracker?.seq ?? _openSeq,
      'source': source ?? tracker?.source ?? 'auto',
      'key': key,
      'blackSuspect': tracker?.firstFrameMissLogged ?? false,
    });
  }

  /// 切换/退出时旧 player 与 texture 的 dispose 结果。
  static void disposeResult({
    required bool ok,
    String? error,
    required int elapsedMs,
    String scope = 'page-shutdown',
  }) {
    if (!kDiagEnabled) return;
    _append('dispose-result', <String, Object?>{
      'seq': _openSeq,
      'scope': scope,
      'ok': ok,
      'error': error,
      'elapsedMs': elapsedMs,
    });
    // 页面已经退出，延迟批量写可能等不到下一次定时器，这里立即落盘。
    unawaited(flush());
  }

  /// 页面退出时统一收尾。
  static void stop() {
    if (!kDiagEnabled) return;
    stopSampling();
    _stopOpenProbe();
    _appendSessionSummary();
    unawaited(flush());
  }

  static void _appendSessionSummary() {
    if (_sessionStartedAt == 0) return;
    Map<String, Object?> bySource(String key) => <String, Object?>{
      'open': _sessionOpenBySource[key] ?? 0,
      'black': _sessionBlackBySource[key] ?? 0,
    };
    _append('session-summary', <String, Object?>{
      'openedCount': _sessionOpenBySource.values.fold<int>(
        0,
        (sum, value) => sum + value,
      ),
      'blackCount': _sessionBlackCount,
      'distinctTextureCount': _sessionTextureIds.length,
      'pageAliveMs': sessionElapsedMs,
      'bySource': <String, Object?>{
        'auto': bySource('auto'),
        'next': bySource('next'),
        'playlistSelect': bySource('playlist-select'),
        'initial': bySource('initial'),
      },
    });
    _sessionStartedAt = 0;
  }

  /// 把 Documents 下的诊断文件打成一个 zip，并交给系统分享面板。
  ///
  /// 缺失的文件直接跳过；没有任何文件或打包失败返回 null，不弹异常。
  static Future<String?> exportAndShare() async {
    if (!kDiagEnabled) return null;
    // 先把缓冲里的最后几行落盘，否则刚写的事件会漏出诊断包。
    await flush();
    File? zipFile;
    try {
      final dir = await _docDir();
      final entries = <Map<String, String>>[];
      for (final name in <String>[
        'pip_trace.log',
        kDiagPlaybackFile,
        PiliRootScan.fileName,
        'ui_hierarchy.txt',
      ]) {
        final file = File('${dir.path}/$name');
        if (!file.existsSync() || file.lengthSync() == 0) continue;
        entries.add(<String, String>{'name': name, 'path': file.path});
      }
      if (entries.isEmpty) return null;
      zipFile = File('${dir.path}/diag_${_timestamp()}.zip');
      final zipPath = zipFile.path;
      final zipEntries = entries;
      // pip_trace 是逐帧日志，大包能到几十 MB；压缩放在单独 isolate，
      // 避免导出按钮点下去主 isolate 整块卡住。
      await Isolate.run(() => _encodeZip(zipEntries, zipPath));
      // 新包写成之后再清旧包：压缩失败时至少还留着上一份可用的诊断包。
      // 诊断包只需要最新一份，避免 Documents 里越攒越多。
      await _deleteOldExports(dir, keep: zipPath);
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

  static Future<void> _deleteOldExports(Directory dir, {required String keep}) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (entity.path == keep) continue;
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        if (!name.startsWith('diag_') || !name.endsWith('.zip')) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static void _pollOpen() {
    if (!kDiagEnabled) return;
    final sw = Stopwatch()..start();
    try {
      _pollOpenOnce();
    } finally {
      _passiveUiBlock('open-poll', sw);
    }
  }

  static void _pollOpenOnce() {
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
      if (textureId != null) {
        tracker.newTextureId = textureId;
        _sessionTextureIds.add(textureId);
      }
      final status = player.dataStatus.value;
      if (status == DataStatus.loading) tracker.sawLoading = true;
      // 切条刚开始时 position 还是上一条的，不能直接当新视频首帧。
      // 纹理换了，或位置已经回到起播区间，才认为新视频真的出画面了。
      final textureChanged =
          textureId != null &&
          tracker.oldTextureId != null &&
          textureId != tracker.oldTextureId;
      final positionReset = tracker.startPositionMs != null
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
      // 只有确实没拿到首帧（firstFrameAt 仍为空）才记首帧缺失。
      // video-params/w 必须实时读：3 秒缓存快照在刚切条时可能是 null，
      // 会把正常播放误判成黑屏，污染证据。
      if (!tracker.firstFrameMissLogged &&
          tracker.firstFrameAt == null &&
          elapsed >= _blackScreenCheckMs) {
        tracker.firstFrameMissLogged = true;
        _markBlack(tracker);
        _append('first-frame-miss', <String, Object?>{
          'seq': tracker.seq,
          'source': tracker.source,
          'index': tracker.index,
          'key': tracker.key,
          'afterOpenMs': elapsed,
          'positionMs': position,
          'videoParamsW': _liveNum(player, 'video-params/w'),
          'dataStatus': status.name,
          'textureId': textureId,
          'audioReady': _audioReady(player),
        });
      }
      // open 已收尾后计时器还要留到 3 秒黑屏判定，不能把正常完成的一批
      // 误记成「5 秒没结束」。
      if (!tracker.ended && !tracker.stuckLogged && elapsed >= _openStuckMs) {
        tracker.stuckLogged = true;
        _append('open-stuck', <String, Object?>{
          'seq': tracker.seq,
          'source': tracker.source,
          'index': tracker.index,
          'elapsedMs': elapsed,
          'phase': tracker.phase,
        });
      }
      if (!_openSlowPoll && elapsed >= _openFastWindowMs) {
        _openSlowPoll = true;
        _rearmOpenTimer(_openSlowPollMs);
      }
      final checkFrom = tracker.firstFrameAt ?? tracker.startedAt;
      if (!tracker.blackChecked &&
          now - checkFrom >= _blackScreenCheckMs &&
          position > 0) {
        tracker.blackChecked = true;
        _checkBlackScreen(tracker, player, position, elapsed);
      }
      if (elapsed >= _openProbeTimeoutMs) {
        if (tracker.firstFrameAt == null) {
          _append('diag_event', <String, Object?>{
            'event': 'open-no-first-frame',
            'seq': tracker.seq,
            'source': tracker.source,
            'index': tracker.index,
            'elapsedMs': elapsed,
          });
        }
        // 只停轮询，保留 tracker：真正卡住的 _open 收尾时还要写
        // open-end / open-seq，否则这条 open 的出口证据会丢。
        _openTimer?.cancel();
        _openTimer = null;
        _openSlowPoll = false;
      }
    } catch (_) {}
  }

  static void _checkBlackScreen(
    _OpenTracker tracker,
    PlPlayerController player,
    int position,
    int elapsed,
  ) {
    // 判定用实时读取，不能吃缓存：切条后的旧快照宽高可能是 null。
    final width = _liveNum(player, 'video-params/w');
    final drop = _liveNum(player, 'drop-frame-count');
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
    // 真的要留证时才完整刷新一次，保证日志里的宽高/解码字段不是陈旧值。
    final snap = snapshot(full: true);
    _markBlack(tracker);
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

  static void _markBlack(_OpenTracker tracker) {
    if (tracker.blackCounted) return;
    tracker.blackCounted = true;
    _sessionBlackCount += 1;
    _sessionBlackBySource[tracker.source] =
        (_sessionBlackBySource[tracker.source] ?? 0) + 1;
  }

  /// 有声音没画面：优先看 mpv 是否已经识别出音频轨；读不到时退回
  /// 「正在播且不在缓冲」这个保守判断。
  static bool? _audioReady(PlPlayerController player) {
    try {
      final codec = player.videoPlayerController?.getProperty('audio-codec');
      if (codec != null && codec.isNotEmpty) return true;
    } catch (_) {}
    try {
      return player.playerStatus.isPlaying && !player.isBuffering.value;
    } catch (_) {
      return null;
    }
  }

  static void _stopOpenProbe() {
    _openTimer?.cancel();
    _openTimer = null;
    _openSlowPoll = false;
    _tracker = null;
  }

  static void _rearmOpenTimer(int ms) {
    _openTimer?.cancel();
    _openTimer = Timer.periodic(
      Duration(milliseconds: ms),
      (_) => _pollOpen(),
    );
  }

  static void _eventIfSlow(
    String step,
    Stopwatch sw, [
    Map<String, Object?> extra = const {},
  ]) {
    final ms = sw.elapsedMilliseconds;
    if (ms < _uiBlockMs) return;
    event('ui-block', <String, Object?>{
      'stage': 'diag',
      'step': step,
      'ms': ms,
      ...extra,
    });
  }

  static void _passiveUiBlock(String step, Stopwatch sw) {
    final ms = sw.elapsedMilliseconds;
    if (ms < _uiBlockMs) return;
    event('ui-block', <String, Object?>{
      'stage': 'diag',
      'step': step,
      'ms': ms,
    });
  }

  static void _append(String tag, Map<String, Object?> fields) {
    if (!kDiagEnabled) return;
    final line = jsonEncode(<String, Object?>{
      't': DateTime.now().millisecondsSinceEpoch,
      'tag': tag,
      ...fields,
    });
    _writeBuffer.add(line);
    if (_writeBuffer.length >= _writeBatchLines) {
      _flushBuffer();
    } else {
      _writeFlushTimer ??= Timer(
        const Duration(milliseconds: _writeFlushDelayMs),
        _flushBuffer,
      );
    }
  }

  /// 把当前缓冲整批交给写链。每 8 批做一次 fsync，既保留掉电前大部分
  /// 日志，又不再让每一行都等磁盘 flush。
  static void _flushBuffer() {
    _writeFlushTimer?.cancel();
    _writeFlushTimer = null;
    if (_writeBuffer.isEmpty) return;
    final chunk = '${_writeBuffer.join('\n')}\n';
    _writeBuffer.clear();
    _writeBatchCount += 1;
    final sync = _writeBatchCount % 8 == 0;
    _writeChain = _writeChain.then((_) => _writeChunk(chunk, sync: sync));
  }

  static Future<void> _writeChunk(String chunk, {required bool sync}) async {
    try {
      final dir = await _docDir();
      final file = File('${dir.path}/$kDiagPlaybackFile');
      if (_playbackBytes < 0) {
        _playbackBytes = file.existsSync() ? file.lengthSync() : 0;
      }
      await file.writeAsString(
        chunk,
        mode: FileMode.append,
        flush: sync,
      );
      _playbackBytes += utf8.encode(chunk).length;
      if (_playbackBytes > _maxPlaybackLogBytes) {
        _playbackBytes = await _rotatePlaybackLog(file);
      }
    } catch (_) {}
  }

  /// 超过上限时只保留末尾约一半，并丢掉第一行残片，保证 JSONL 完整。
  static Future<int> _rotatePlaybackLog(File file) async {
    try {
      final length = await file.length();
      if (length <= _playbackLogKeepBytes) return length;
      final raf = await file.open(mode: FileMode.read);
      List<int> tail;
      try {
        await raf.setPosition(length - _playbackLogKeepBytes);
        tail = await raf.read(_playbackLogKeepBytes);
      } finally {
        await raf.close();
      }
      final firstNewline = tail.indexOf(0x0A);
      if (firstNewline >= 0 && firstNewline + 1 < tail.length) {
        tail = tail.sublist(firstNewline + 1);
      }
      await file.writeAsBytes(tail, flush: false);
      return tail.length;
    } catch (_) {
      // 截断失败：把计数标成未知，下次写重新 stat 真实大小，
      // 避免用错误计数把滚动判定卡死。
      return -1;
    }
  }

  /// 导出前/退出时把缓冲刷干净。
  static Future<void> flush() async {
    _flushBuffer();
    try {
      await _writeChain;
    } catch (_) {}
  }

  static void _encodeZip(List<Map<String, String>> entries, String zipPath) {
    final out = OutputFileStream(zipPath);
    final encoder = ZipEncoder();
    try {
      encoder.startEncode(out);
      for (final entry in entries) {
        encoder.add(
          ArchiveFile.stream(
            entry['name']!,
            InputFileStream(entry['path']!),
          ),
        );
      }
      encoder.endEncode();
    } finally {
      out.close();
    }
  }

  static num? _asNum(Object? value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  static int? _asInt(Object? value) => _asNum(value)?.toInt();

  /// 实时读取单个 mpv 属性，绕过 [_mpvCache]。
  static num? _liveNum(PlPlayerController player, String key) {
    try {
      final raw = player.videoPlayerController?.getProperty(key);
      if (raw != null && raw.isNotEmpty) return num.tryParse(raw);
    } catch (_) {}
    return null;
  }

  static String _timestamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}

final class _OpenTracker {
  _OpenTracker({
    required this.seq,
    required this.source,
    required this.index,
    required this.key,
    required this.startedAt,
    required this.oldTextureId,
    required this.startPositionMs,
    required this.dropBaseline,
  });

  final int seq;
  final String source;
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
  bool blackCounted = false;
  bool firstFrameMissLogged = false;
  bool stuckLogged = false;
  bool ended = false;
  String phase = 'resolve';
}
