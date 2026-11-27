import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:PiliPlus/pages/douyin/rootscan.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
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

/// 深度诊断开关。
///
/// 默认关闭：正常播放不采样，只在开流/首帧/异常/导出时各完整读取一次，
/// 避免同步 FFI 把主 isolate 拖住。需要更细的轮转读取时用
/// `--dart-define=PILIPLUS_DIAG_VERBOSE=true` 打开。
const bool kDiagVerbose = bool.fromEnvironment('PILIPLUS_DIAG_VERBOSE');

/// mpv 解码/渲染侧需要入证的指标。读不到会在采样里写明原因，不抛错。
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

/// mpv 属性别名：键是采样里对外稳定的名字，值才是 mpv 真正支持的属性名。
///
/// - `drop-frame-count` 在部分 libmpv/老版本里叫 `frame-drop-count`；
/// - `video-params/pixfmt` 不是 mpv 的属性（`video-params` 的子项叫
///   `pixelformat`）。
///
/// 直接读原键只会拿到空串，采样里就永远是 null。这里显式回退，并把真正
/// 命中的键写进 `mpvKeysUsed`，避免又变成「静默 null」。
const Map<String, String> _mpvAliases = <String, String>{
  'drop-frame-count': 'frame-drop-count',
  'video-params/pixfmt': 'video-params/pixelformat',
};

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

/// 调用方显式要轻量快照（`snapshot(full: false)`）时，按 [_mpvLightKeys]
/// 轮转补读 mpv 指标。
///
/// 正常播放已经不再周期性采样，只剩开流/首帧/异常/导出这些一次性采样，
/// 它们都走完整读取。这条轻量路径留给仍然愿意按拍轮转的调用方：每拍只读
/// 一个键，不会把主 isolate 一次卡住半秒。
const int _mpvLightRefreshMs = 2500;

/// 轮转顺序：先补黑屏判定/硬解取证最关键的三个，其余靠后。
const List<String> _mpvLightKeys = <String>[
  'video-params/w',
  'hwdec-current',
  'video-codec',
  'drop-frame-count',
  'video-params/h',
  'video-params/pixfmt',
  'estimated-vf-fps',
  'vo-drop-frame-count',
  'decoder-frame-drop-count',
  'cache-speed',
  'demuxer-cache-time',
];

/// verbose 模式下的轻量快照整轮刷新间隔。
const int _mpvVerboseRefreshMs = 1000;

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

  /// 本次 run 的唯一标识。
  ///
  /// 每条日志都带 `runId`，导出后可直接按 run 过滤；`startSession()` 会
  /// 生成新值并清空上一 run 的落盘文件，避免旧行混进本次判定。
  static String _runId = '';
  static int _runSeq = 0;

  /// 设备信息缓存（原生 `appInfo`）。session 很短时 summary 最多等 800ms。
  static Map<String, Object?> _deviceInfo = <String, Object?>{};
  static Future<Map<String, Object?>>? _deviceInfoFuture;

  /// 混播续播聚合计数，`stop()` 时写进 `session-summary`。
  static int _sessionPlayedItems = 0;
  static final Set<String> _sessionPlayedKeys = <String>{};
  static int _sessionItemSkipCount = 0;
  static int _sessionItemSkipEventCount = 0;
  static int _sessionSkipStopCount = 0;
  static int _sessionMaxConsecutiveSkip = 0;
  static int _sessionPipSwitchCount = 0;
  static int _sessionBiliRetryCount = 0;
  static bool _pipEverActive = false;

  /// 纹理生命周期账本：textureId -> source。
  ///
  /// 只统计 controller 通过 [PlPlayerController.textureObserver] 上报的纹理，
  /// 用来验证「切条前旧纹理已释放」与会话内并发纹理数上限。
  static final Map<int, String> _aliveTextures = <int, String>{};
  static final Map<String, int> _aliveBySource = <String, int>{};
  static int _textureCreateSeq = 0;
  static int _textureReleaseSeq = 0;
  static int _textureReleaseFailedCount = 0;
  static int _sessionMaxAliveTexture = 0;

  /// 最近一次 App 回到前台的时间，以及「回前台后首个请求」的待消费标记。
  ///
  /// 网络失败取证需要知道失败请求离最近一次 resume 有多久、是不是 resume
  /// 后的第一个请求；状态只在这里保存，http/mobile_observer 只读调用。
  static int _lastResumeAtMs = 0;
  static bool _awaitFirstRequestAfterResume = false;
  static bool _lastResumeWasLongIdle = false;

  /// 上一次完整读取 mpv 属性的时间与结果。
  static int _mpvCacheAt = 0;
  static int _mpvLightRefreshAt = 0;
  static int _mpvLightCursor = 0;
  static final Map<String, Object?> _mpvCache = <String, Object?>{};

  /// 本轮完整读取里确实没拿到值的键 -> 原因。采样直接带上，绝不留静默 null。
  static final Map<String, String> _mpvMissing = <String, String>{};

  /// 通过别名读到值的键 -> 真正命中的 mpv 属性名。
  static final Map<String, String> _mpvKeyUsed = <String, String>{};

  static Future<Directory> _docDir() =>
      _documentsDir ??= getApplicationDocumentsDirectory();

  /// 抖音页当前是否在逐帧采样 FlutterTexture。
  ///
  /// PiP 活跃时页面会把内嵌视频层换成占位，避免和原生小窗同时从同一纹理
  /// 取帧。这里由 player 页维护，只用于诊断：每条日志都带上该值，配合
  /// [IOSPipHelper.isActive] 即可证明同一时刻只有一个消费者。
  static bool frontFramePulling = false;

  /// PiP 活跃时页内是否只挂着 2×2 的最小纹理消费者。
  ///
  /// 为真表示没有整块视频层，但 Flutter 仍在按帧从 texture 取 buffer；
  /// 配合原生 `pip-frame-health` 可区分「没有新帧」与「页内根本没消费」。
  static bool pipFrameKeepAlive = false;

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
    _beginRun();
    _openSeq = 0;
    _sessionBlackCount = 0;
    _sessionTextureIds.clear();
    _sessionOpenBySource.clear();
    _sessionBlackBySource.clear();
    _sessionMaxAliveTexture = 0;
    _aliveTextures.clear();
    _aliveBySource.clear();
    _textureCreateSeq = 0;
    _textureReleaseSeq = 0;
    _textureReleaseFailedCount = 0;
    PlPlayerController.textureObserver = _onTextureEvent;
    // 进入播放页时单例可能还带着上一条的 texture（PiP / 共享实例）。此时
    // 调用方还没把 textureSource 改成 douyin，先按 carry 登记，避免把来
    // 源打错成 douyin，导致 aliveBySource 无法区分。
    final carry = _currentTextureId();
    if (carry != null) {
      textureLife(
        event: 'carry',
        textureId: carry,
        source: 'carry',
        reason: 'session-start',
      );
    }
  }

  /// 开始一轮新的诊断 run：新 runId、清空上一轮聚合计数，并把上一轮的
  /// 诊断文件清空。旧缓冲先排进写链，再清文件，保证旧行不会落进新 run。
  static void _beginRun() {
    _runSeq += 1;
    _runId =
        '${DateTime.now().millisecondsSinceEpoch}-'
        '${_runSeq.toString().padLeft(3, '0')}';
    _sessionPlayedItems = 0;
    _sessionPlayedKeys.clear();
    _sessionItemSkipCount = 0;
    _sessionItemSkipEventCount = 0;
    _sessionSkipStopCount = 0;
    _sessionMaxConsecutiveSkip = 0;
    _sessionPipSwitchCount = 0;
    _sessionBiliRetryCount = 0;
    _pipEverActive = IOSPipHelper.isActive;
    _deviceInfo = <String, Object?>{};
    _deviceInfoFuture = appInfo().then((info) {
      _deviceInfo = info;
      return info;
    });
    _flushBuffer();
    _writeChain = _writeChain.then((_) => _resetRunArtifacts());
    _sessionStartedAt = DateTime.now().millisecondsSinceEpoch;
    _append('session-start', <String, Object?>{
      'runId': _runId,
      'runSeq': _runSeq,
      'pipActive': IOSPipHelper.isActive,
      'pipLite': pipLiteMode,
      'diagVerbose': kDiagVerbose,
    });
  }

  /// 清空上一 run 的追加型诊断文件。失败只影响体积，不影响本次采样。
  ///
  /// `pip_trace.log` 由原生常驻句柄追加，这里只截断不删除：原生下次
  /// `seekToEnd` 会从 0 继续写，不会把文件写坏。rootscan.json /
  /// ui_hierarchy.txt 每次都是整文件覆盖，不在这里截断，避免和本次
  /// postFrame 的写入抢时序。
  static Future<void> _resetRunArtifacts() async {
    try {
      final dir = await _docDir();
      for (final name in <String>[kDiagPlaybackFile, 'pip_trace.log']) {
        try {
          final file = File('${dir.path}/$name');
          if (await file.exists()) {
            await file.writeAsString('', flush: false);
          }
        } catch (_) {}
      }
      _playbackBytes = 0;
      // 旧诊断包同样只保留本轮导出的那一份，避免 Documents 里累计。
      await _deleteOldExports(dir, keep: '');
    } catch (_) {}
  }

  static int? _currentTextureId() {
    try {
      return PlPlayerController.instance?.videoController?.id.value;
    } catch (_) {
      return null;
    }
  }

  static void _onTextureEvent(
    String event,
    int? textureId,
    String source,
    String reason,
  ) {
    textureLife(
      event: event,
      textureId: textureId,
      source: source,
      reason: reason,
    );
  }

  /// 记录一次纹理创建/释放。release 后 alive 立刻减一，用来证明切条不是
  /// 「新建一条、旧的不拆」。
  static void textureLife({
    required String event,
    required int? textureId,
    String source = 'unknown',
    String reason = '',
  }) {
    if (!kDiagEnabled || textureId == null) return;
    if (event == 'create') _textureCreateSeq += 1;
    String? releasedSource;
    if (event == 'create' || event == 'carry') {
      if (!_aliveTextures.containsKey(textureId)) {
        _aliveTextures[textureId] = source;
        _aliveBySource[source] = (_aliveBySource[source] ?? 0) + 1;
      }
      _sessionTextureIds.add(textureId);
    } else if (event == 'release') {
      _textureReleaseSeq += 1;
      final prev = _aliveTextures.remove(textureId);
      releasedSource = prev;
      if (prev != null) {
        final left = (_aliveBySource[prev] ?? 1) - 1;
        if (left <= 0) {
          _aliveBySource.remove(prev);
        } else {
          _aliveBySource[prev] = left;
        }
      }
    } else if (event == 'release-failed') {
      // 原生 dispose 失败：纹理可能还活着，alive 必须保持不变。单独计数，
      // 免得「release 后 alive 立刻下降」被失败事件伪造成成功。
      _textureReleaseFailedCount += 1;
    }
    if (_aliveTextures.length > _sessionMaxAliveTexture) {
      _sessionMaxAliveTexture = _aliveTextures.length;
    }
    _append('texture-life', <String, Object?>{
      'event': event,
      'textureId': textureId,
      'source': releasedSource ?? source,
      'reason': reason,
      'alive': _aliveTextures.length,
      'maxAlive': _sessionMaxAliveTexture,
      'aliveBySource': Map<String, int>.of(_aliveBySource),
      'textureCreateSeq': _textureCreateSeq,
      'textureReleaseSeq': _textureReleaseSeq,
      'textureReleaseFailedCount': _textureReleaseFailedCount,
    });
  }

  /// 本页从进入到现在经过的毫秒数；未开会话时返回 0。
  static int get sessionElapsedMs => _sessionStartedAt == 0
      ? 0
      : DateTime.now().millisecondsSinceEpoch - _sessionStartedAt;

  /// 一次读取当前播放器的 mpv 指标、position 与 textureId。
  ///
  /// rootscan 也直接复用这个快照，保证两处字段完全一致。诊断已改为按需
  /// 采样，默认就是完整读取：否则 rootscan 拿到的会是一份空缓存。
  static Map<String, Object?> snapshot({
    bool full = true,
    bool refresh = true,
    bool readMpv = true,
    String skippedMpvReason = 'not-sampled',
  }) {
    final out = <String, Object?>{
      'positionMs': null,
      'textureId': null,
      'dataStatus': null,
      'pipActive': IOSPipHelper.isActive,
      'frontFramePull': frontFramePulling,
      'pipFrameKeepAlive': pipFrameKeepAlive,
    };
    PlPlayerController? player;
    try {
      player = PlPlayerController.instance;
    } catch (_) {}
    if (player == null) {
      for (final key in kMpvDiagKeys) {
        out[key] = null;
      }
      out['mpvMissing'] = <String, String>{
        for (final key in kMpvDiagKeys) key: 'no-player',
      };
      out['mpvKeysUsed'] = <String, String>{};
      return out;
    }
    try {
      out['positionMs'] = player.positionInMilliseconds;
      out['textureId'] = player.videoController?.id.value;
      out['dataStatus'] = player.dataStatus.value.name;
    } catch (_) {}

    // `getProperty` 是同步 FFI 调用，mpv 核心忙时会阻塞调用线程。按需完整
    // 采样时整轮读取；调用方显式要轻量快照（full: false）时每拍只轮转补读
    // 一个指标，避免把主 isolate 一次卡住半秒。
    if (refresh && readMpv) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (full) {
        _refreshMpv(player, now);
      } else if (kDiagVerbose) {
        if (now - _mpvCacheAt >= _mpvVerboseRefreshMs) {
          _refreshMpv(player, now);
        }
      } else if (player.dataStatus.value == DataStatus.loaded &&
          now - _mpvLightRefreshAt >= _mpvLightRefreshMs) {
        _mpvLightRefreshAt = now;
        final key = _mpvLightKeys[_mpvLightCursor % _mpvLightKeys.length];
        _mpvLightCursor += 1;
        _readMpvKey(player, key);
      }
    }
    if (!readMpv) {
      // 明确「这次不读」的采样（如 open-start）：所有键都写原因，绝不静默 null。
      for (final key in kMpvDiagKeys) {
        out[key] = null;
      }
      out['mpvMissing'] = <String, String>{
        for (final key in kMpvDiagKeys) key: skippedMpvReason,
      };
      out['mpvKeysUsed'] = <String, String>{};
      return out;
    }
    for (final key in kMpvDiagKeys) {
      out[key] = _mpvCache[key];
    }
    out['mpvMissing'] = Map<String, String>.of(_mpvMissing);
    out['mpvKeysUsed'] = Map<String, String>.of(_mpvKeyUsed);
    return out;
  }

  /// 只返回上一次采样留下的缓存，不触发任何 mpv 读取。
  ///
  /// 页内面板展示用：正常播放不该因为用户点开一个面板就再多采一轮，
  /// 采样时机仍限定在开流/首帧/异常/导出。
  static Map<String, Object?> cachedSnapshot() =>
      snapshot(full: false, refresh: false);

  static void _refreshMpv(PlPlayerController player, int now) {
    _mpvMissing.clear();
    _mpvKeyUsed.clear();
    for (final key in kMpvDiagKeys) {
      _readMpvKey(player, key, strict: true);
    }
    _mpvCacheAt = now;
    _mpvLightRefreshAt = now;
  }

  static void _readMpvKey(
    PlPlayerController player,
    String key, {
    bool strict = false,
  }) {
    final (value, reason) = _readLiveKey(player, key);
    if (value != null && value.isNotEmpty) {
      _mpvCache[key] = value;
      _mpvMissing.remove(key);
      return;
    }
    // 完整刷新必须丢弃读空/读失败的陈旧值：切到新视频时，上一条的丢帧
    // 数/解码器绝不能留在缓存里被当成本条上报。轻量轮转（非 strict）仍
    // 保留旧值，避免 mpv 偶发繁忙把已经拿到的指标抹掉。
    if (strict || !_mpvCache.containsKey(key)) {
      _mpvCache.remove(key);
      _mpvMissing[key] = reason ?? 'unknown';
    }
  }

  /// 切条前后 mpv 状态会整体换掉，缓存必须作废，否则新视频的宽高/解码
  /// 指标要等到下一次完整刷新才更新。
  static void invalidateSnapshotCache() {
    _mpvCache.clear();
    _mpvMissing.clear();
    _mpvKeyUsed.clear();
    _mpvCacheAt = 0;
    _mpvLightRefreshAt = 0;
    _mpvLightCursor = 0;
  }

  /// 一次性采样，写一行 `probe`。正常播放不调用。
  ///
  /// 只在开流、首帧、异常判定和用户导出诊断时调用：mpv 的 `getProperty`
  /// 是同步 FFI，常驻采样在开流/seek 期间会和解码锁抢主 isolate。这里
  /// 把时机收敛到少量关键点，每次完整读取全部指标。
  static Map<String, Object?> probeOnce(
    String reason, {
    Map<String, Object?> extra = const {},
    bool readMpv = true,
  }) {
    final out = snapshot(
      full: true,
      readMpv: readMpv,
      skippedMpvReason: 'not-sampled-at-$reason',
    );
    if (!kDiagEnabled) return out;
    _append('probe', <String, Object?>{'reason': reason, ...extra, ...out});
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

  /// 写一条 `diag_event`，用于记录 Dart 主 isolate 的卡顿等一次性事件。
  static void event(String event, [Map<String, Object?> fields = const {}]) {
    if (!kDiagEnabled) return;
    // ticker-gap 只由 PiP ticker（500ms，仅 armed/active 时运行）逐拍
    // 上报；这里统一按 3 倍间隔过滤，只在真正停顿时留证，避免刷出几万条。
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
    // 这次 open 实际请求的 hwdec（auto / auto-copy），写进 open 事件，
    // 方便对比直通与回滚前后。
    String? hwdecRequested,
  }) {
    if (!kDiagEnabled) return;
    final sw = Stopwatch()..start();
    _stopOpenProbe();
    invalidateSnapshotCache();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    // 开流瞬间只记 position/texture/status：此刻 player 可能还绑在上一
    // 条媒体上，读 mpv 会把旧视频的丢帧/解码指标回填进新缓存。丢帧基线
    // 改为首帧完整采样时再取。
    final snap = probeOnce(
      'open-start',
      readMpv: false,
      extra: <String, Object?>{
        'index': index,
        'key': key,
        'oldTextureId': oldTextureId,
        'source': source,
      },
    );
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
      dropBaseline: null,
      hwdecRequested: hwdecRequested,
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
      'hwdecRequested': hwdecRequested,
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
    // open 收尾（含失败）采样一次，完整读取本轮 mpv 指标。
    final snap = probeOnce('open-end', extra: <String, Object?>{
      'seq': tracker.seq,
      'source': tracker.source,
      'index': tracker.index,
      'error': error,
    });
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
    _stopOpenProbe();
    PlPlayerController.textureObserver = null;
    final summary = _buildSessionSummary();
    if (summary == null) {
      unawaited(flush());
    } else {
      unawaited(_appendSummaryAndFlush(summary));
    }
  }

  /// 抓取 session 结束时的快照。必须在 [_sessionStartedAt] 清零前调用，
  /// 否则 `pageAliveMs` 会被算成 0；重复调用返回 null，不会写两条 summary。
  static Map<String, Object?>? _buildSessionSummary() {
    if (_sessionStartedAt == 0) return null;
    Map<String, Object?> bySource(String key) => <String, Object?>{
      'open': _sessionOpenBySource[key] ?? 0,
      'black': _sessionBlackBySource[key] ?? 0,
    };
    final summary = <String, Object?>{
      'runId': _runId,
      'playedItemCount': _sessionPlayedItems,
      'distinctItemCount': _sessionPlayedKeys.length,
      'itemSkipCount': _sessionItemSkipCount,
      'itemSkipEventCount': _sessionItemSkipEventCount,
      'skipStopCount': _sessionSkipStopCount,
      'maxConsecutiveSkip': _sessionMaxConsecutiveSkip,
      'pipSwitchCount': _sessionPipSwitchCount,
      'biliFirstFrameRetryCount': _sessionBiliRetryCount,
      'pipActive': IOSPipHelper.isActive,
      'pipEverActive': _pipEverActive,
      'openedCount': _sessionOpenBySource.values.fold<int>(
        0,
        (sum, value) => sum + value,
      ),
      'blackCount': _sessionBlackCount,
      'distinctTextureCount': _sessionTextureIds.length,
      'maxAliveTexture': _sessionMaxAliveTexture,
      'aliveTextureAtEnd': _aliveTextures.length,
      'aliveTextureBySource': Map<String, int>.of(_aliveBySource),
      'textureCreateCount': _textureCreateSeq,
      'textureReleaseCount': _textureReleaseSeq,
      'textureReleaseFailedCount': _textureReleaseFailedCount,
      'pageAliveMs': sessionElapsedMs,
      'bySource': <String, Object?>{
        'auto': bySource('auto'),
        'next': bySource('next'),
        'playlistSelect': bySource('playlist-select'),
        'initial': bySource('initial'),
      },
    };
    _sessionStartedAt = 0;
    return summary;
  }

  /// 设备型号由原生通道异步读取；session 太短时最多等 800ms，拿不到就
  /// 只写 Dart 侧能拿到的系统版本，绝不为了机型卡住退出流程。
  static Future<void> _appendSummaryAndFlush(
    Map<String, Object?> summary,
  ) async {
    var info = _deviceInfo;
    if ((info['model'] as String?)?.isNotEmpty != true) {
      try {
        info = await (_deviceInfoFuture ?? appInfo()).timeout(
          const Duration(milliseconds: 800),
        );
      } catch (_) {}
    }
    // 取机型期间若已开始下一 run，旧 summary 不能再写进新 run 的文件。
    if (summary['runId'] != _runId) return;
    final model = info['model'] as String?;
    _append('session-summary', <String, Object?>{
      ...summary,
      'model': model,
      'deviceLabel': _deviceLabel(model),
      'systemVersion': info['systemVersion'] ?? Platform.operatingSystemVersion,
      'appVersion': info['version'],
      'appBuild': info['build'],
      'app': info,
    });
    await flush();
  }

  /// 把硬件标识翻成测试同事看得懂的机型；未知型号保留原始值。
  static String? _deviceLabel(String? model) {
    if (model == null || model.isEmpty) return null;
    const labels = <String, String>{
      'iPhone8,1': 'iPhone 6s',
      'iPhone8,2': 'iPhone 6s Plus',
      'iPhone15,2': 'iPhone 15 Pro',
      'iPhone15,3': 'iPhone 15 Pro Max',
    };
    return labels[model] ?? model;
  }

  /// 把 Documents 下的诊断文件打成一个 zip，并交给系统分享面板。
  ///
  /// 缺失的文件直接跳过；没有任何文件或打包失败返回 null，不弹异常。
  static Future<String?> exportAndShare() async {
    if (!kDiagEnabled) return null;
    // 用户主动导出诊断时补采一次，保证包里有一份当前播放状态的完整读数。
    probeOnce('export');
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
        // 首帧这一刻解码器已初始化、mpv 不忙：完整采样一次，拿到实际
        // 分辨率/像素格式/解码器/丢帧等全部指标。丢帧基线也在这一刻重取，
        // 避免拿上一条的累计丢帧数算增量。
        final snap = probeOnce('first-frame', extra: <String, Object?>{
          'seq': tracker.seq,
          'source': tracker.source,
          'index': tracker.index,
          'textureId': textureId,
        });
        final firstWidth = _asNum(snap['video-params/w']);
        final firstCodec = snap['video-codec'] as String?;
        final firstHwdec = snap['hwdec-current'] as String?;
        tracker.dropBaseline = _asInt(snap['drop-frame-count']);
        _append('open-first-frame', <String, Object?>{
          'index': tracker.index,
          'textureId': textureId,
          'positionMs': position,
          'afterOpenMs': now - tracker.startedAt,
          'afterLoadedMs': tracker.loadedAt == null
              ? null
              : now - tracker.loadedAt!,
          'videoParamsW': firstWidth,
          'videoCodec': firstCodec,
          'hwdec': firstHwdec,
          'hwdecRequested': tracker.hwdecRequested,
        });
      }
      final elapsed = now - tracker.startedAt;
      // 只有数据源已经 loaded（还在开流是「慢」，交给 open-stuck 留证）且确实
      // 没拿到首帧时才判缺失；判之前实时复核 video-params/w 和播放状态，
      // 已经解出画面的正常播放绝不记黑屏。
      if (!tracker.firstFrameMissLogged &&
          tracker.firstFrameAt == null &&
          elapsed >= _blackScreenCheckMs &&
          status == DataStatus.loaded) {
        final liveWidth = _liveNum(player, 'video-params/w');
        final playing = player.playerStatus.isPlaying;
        // 起播瞬间可能刚好读到「playing 已置位、宽高还没写回」的一拍，
        // 连续两拍都在播才认定为缺画面，避免把正常起播误判成黑屏。
        final playingConfirmed = playing && tracker.sawPlaying;
        tracker.sawPlaying = playing;
        if (liveWidth != null && liveWidth > 0) {
          // mpv 已经解出画面，只是 position/texture 判据没抓到首帧时序。
          tracker.firstFrameMissLogged = true;
          tracker.firstFrameAt = now;
          _append('open-first-frame-late', <String, Object?>{
            'seq': tracker.seq,
            'source': tracker.source,
            'index': tracker.index,
            'afterOpenMs': elapsed,
            'positionMs': position,
            'videoParamsW': liveWidth,
            'textureId': textureId,
            'hwdec': _readLiveKey(player, 'hwdec-current').$1,
            'hwdecRequested': tracker.hwdecRequested,
          });
        } else if (playingConfirmed) {
          // 正在播却读不到画面参数，才是真正的「有声音没画面」。
          tracker.firstFrameMissLogged = true;
          _markBlack(tracker);
          final snap = probeOnce('first-frame-miss', extra: <String, Object?>{
            'seq': tracker.seq,
            'source': tracker.source,
            'index': tracker.index,
            'key': tracker.key,
          });
          _append('first-frame-miss', <String, Object?>{
            'seq': tracker.seq,
            'source': tracker.source,
            'index': tracker.index,
            'key': tracker.key,
            'afterOpenMs': elapsed,
            'positionMs': position,
            'videoParamsW': liveWidth,
            'videoCodec': snap['video-codec'],
            'hwdec': snap['hwdec-current'],
            'dataStatus': status.name,
            'textureId': textureId,
            'playing': playing,
            'buffering': player.isBuffering.value,
            'audioReady': _audioReady(player),
            'mpvMissing': snap['mpvMissing'],
          });
        } else if (!tracker.pendingLogged) {
          // 暂停 / 未起播时读不到画面参数不能当黑屏，只留一条待定证据。
          // 只防重复写 pending，不占用 firstFrameMissLogged：这里并没有下
          // 「缺画面」的结论，后面真的读到宽度或开始播放时还要能补记。
          tracker.pendingLogged = true;
          _append('diag_event', <String, Object?>{
            'event': 'first-frame-pending',
            'seq': tracker.seq,
            'source': tracker.source,
            'index': tracker.index,
            'afterOpenMs': elapsed,
            'positionMs': position,
            'playing': playing,
            'buffering': player.isBuffering.value,
          });
        }
      }
      // open 已收尾后计时器还要留到 3 秒黑屏判定，不能把正常完成的一批
      // 误记成「5 秒没结束」。
      if (!tracker.ended && !tracker.stuckLogged && elapsed >= _openStuckMs) {
        tracker.stuckLogged = true;
        probeOnce('open-stuck', extra: <String, Object?>{
          'seq': tracker.seq,
          'source': tracker.source,
          'index': tracker.index,
          'phase': tracker.phase,
        });
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
          position > 0 &&
          status == DataStatus.loaded) {
        tracker.blackChecked = true;
        _checkBlackScreen(tracker, player, position, elapsed);
      }
      if (elapsed >= _openProbeTimeoutMs) {
        if (tracker.firstFrameAt == null) {
          probeOnce('open-no-first-frame', extra: <String, Object?>{
            'seq': tracker.seq,
            'source': tracker.source,
            'index': tracker.index,
          });
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
    final playing = player.playerStatus.isPlaying;
    final buffering = player.isBuffering.value;
    String? reason;
    if (width == null) {
      // 暂停 / 仍在缓冲时读不到宽高是正常的，不能算黑屏。
      if (playing) reason = 'video-params/w-null';
    } else if (delta != null && delta >= _dropFrameJumpThreshold) {
      reason = 'drop-frame-count-jump';
    }
    if (reason == null) return;
    // 真的要留证时才完整采样一次，保证日志里的宽高/解码字段不是陈旧值。
    final snap = probeOnce('blackscreen-suspect', extra: <String, Object?>{
      'reason': reason,
      'index': tracker.index,
      'key': tracker.key,
      'elapsedMs': elapsed,
      'positionMs': position,
    });
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
      'playing': playing,
      'buffering': buffering,
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
    if (_runId.isEmpty) {
      _runSeq += 1;
      _runId =
          '${DateTime.now().millisecondsSinceEpoch}-'
          '${_runSeq.toString().padLeft(3, '0')}';
    }
    if (IOSPipHelper.isActive) _pipEverActive = true;
    _trackSessionMetrics(tag, fields);
    final line = jsonEncode(<String, Object?>{
      't': DateTime.now().millisecondsSinceEpoch,
      'tag': tag,
      'runId': _runId,
      ...fields,
      'pipActive': IOSPipHelper.isActive,
      'frontFramePull': frontFramePulling,
      'pipFrameKeepAlive': pipFrameKeepAlive,
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

  /// 从既有事件流里聚合续播指标，避免 player 每个出口再各写一套计数。
  ///
  /// - `pip-switch` 且 allow=true：PiP 内真实发生的切条；
  /// - `bili-firstframe-retry`：B站首帧失败后重取 playurl；
  /// - `play-item`：一次成功起播；
  /// - `item-skip` / `item-skip-stop`：跳过次数与最大连续失败数。
  static void _trackSessionMetrics(
    String tag,
    Map<String, Object?> fields,
  ) {
    if (_sessionStartedAt == 0) return;
    if (tag == 'diag_event') {
      final name = fields['event'];
      if (name == 'pip-switch' && fields['allow'] == true) {
        _sessionPipSwitchCount += 1;
      } else if (name == 'bili-firstframe-retry') {
        _sessionBiliRetryCount += 1;
      } else if (name == 'item-skip') {
        _sessionItemSkipEventCount += 1;
        if (fields['toIndex'] != null) _sessionItemSkipCount += 1;
        _noteSkipAttempt(fields);
      } else if (name == 'item-skip-stop') {
        _sessionSkipStopCount += 1;
        _noteSkipAttempt(fields);
      }
      return;
    }
    if (tag == 'play-item') {
      _sessionPlayedItems += 1;
      final key = fields['key'];
      if (key is String && key.isNotEmpty) _sessionPlayedKeys.add(key);
    }
  }

  static void _noteSkipAttempt(Map<String, Object?> fields) {
    final attempt = _asInt(fields['attempt'] ?? fields['streak']);
    if (attempt != null && attempt > _sessionMaxConsecutiveSkip) {
      _sessionMaxConsecutiveSkip = attempt;
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
  ///
  /// 返回 `(值, 失败原因)`。mpv 对不存在的属性返回空串而不是抛错，所以
  /// 「空串」也要记成原因；[key] 有别名时依次尝试，真正命中的属性名会
  /// 记进 [_mpvKeyUsed]。
  static (String?, String?) _readLiveKey(
    PlPlayerController? player,
    String key,
  ) {
    if (player == null) return (null, 'no-player');
    try {
      final controller = player.videoPlayerController;
      if (controller == null) return (null, 'no-player-controller');
      final alias = _mpvAliases[key];
      final candidates = alias == null
          ? <String>[key]
          : <String>[key, alias];
      final reasons = <String>[];
      for (final candidate in candidates) {
        try {
          final raw = controller.getProperty(candidate);
          if (raw.isNotEmpty) {
            _mpvKeyUsed[key] = candidate;
            return (raw, null);
          }
          reasons.add('$candidate: empty');
        } catch (error) {
          reasons.add('$candidate: $error');
        }
      }
      return (null, reasons.isEmpty ? 'empty-value' : reasons.join('; '));
    } catch (error) {
      return (null, 'controller-error: $error');
    }
  }

  static String? _liveStr(PlPlayerController player, String key) =>
      _readLiveKey(player, key).$1;

  /// 实时读取单个数值型 mpv 属性，绕过 [_mpvCache]。
  static num? _liveNum(PlPlayerController player, String key) {
    final raw = _liveStr(player, key);
    return raw == null ? null : num.tryParse(raw);
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
    this.hwdecRequested,
  });

  final int seq;
  final String source;
  final int index;
  final String key;
  final int startedAt;
  final int? oldTextureId;
  final int? startPositionMs;
  final String? hwdecRequested;
  int? dropBaseline;

  int? newTextureId;
  int? loadedAt;
  int? firstFrameAt;
  bool sawLoading = false;
  bool blackChecked = false;
  bool blackCounted = false;
  bool firstFrameMissLogged = false;
  bool pendingLogged = false;
  bool sawPlaying = false;
  bool stuckLogged = false;
  bool ended = false;
  String phase = 'resolve';
}
