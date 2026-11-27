import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:PiliPlus/common/widgets/player_bar.dart';
import 'package:PiliPlus/common/widgets/progress_bar/audio_video_progress_bar.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart' show Part;
import 'package:PiliPlus/pages/douyin/diag_probe.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/perf.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/playlist.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/rootscan.dart';
import 'package:PiliPlus/pages/douyin/shuffle_store.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:audio_service/audio_service.dart' show MediaControl;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

/// 抖音 / TikTok / B 站收藏的整页播放器。
///
/// 这一版是重建后的干净实现，刻意保持小：
///
/// * 只做「播一条、上下切条、点一下暂停、进小窗」这四件事；
/// * 复用上游 `PlPlayerController`，因此画中画走的是 PiliPlus 自己那套
///   `PipPlugin`（从 Flutter texture 抓帧、CIImage 转格式、系统时基做时间戳），
///   不再自建一条 PiP 帧管道；
/// * 不在这里做任何 QA 埋点。QA 是另一条独立链路，不参与播放逻辑。
///
/// 关于「整个页面像死了」：这里曾经踩过两个坑，别走回头路。
///
/// 一是控件和视频手势几何重叠——把上下条按钮叠在 `Positioned.fill` 的视频
/// 手势上，手指落在按钮上时事件被下面的播放器手势吃掉，点「向下」既不返回
/// 也不暂停。现在控件是 Stack 里独立的 Positioned，和视频区域在几何上分开。
///
/// 二是有人试图用 `AbsorbPointer` 包住控件层「防止事件漏下去」，这是反的：
/// `AbsorbPointer` 是让**子树收不到事件**，等于把所有按钮禁用掉。控件层在
/// Stack 里位于视频层之上，命中测试按逆序走，本来就先到控件层，不需要任何
/// 拦截。详见 `_controls` 的注释。
class ShortVideoPlayerPage extends StatefulWidget {
  const ShortVideoPlayerPage({
    required this.queue,
    required this.index,
    this.showImmediately = false,
    super.key,
  });

  final List<QueueEntry> queue;
  final int index;
  final bool showImmediately;

  @override
  State<ShortVideoPlayerPage> createState() => _ShortVideoPlayerPageState();
}

class _ShortVideoPlayerPageState extends State<ShortVideoPlayerPage>
    with WidgetsBindingObserver {
  late final List<QueueEntry> _queue = List<QueueEntry>.of(widget.queue);
  late int _index = widget.index.clamp(0, _queue.length - 1);

  /// 播放器单例。首帧看门狗自愈时会先 dispose 再重新 getInstance，
  /// 因此不能是 final；否则自动连播复用同一 texture 永远救不回来。
  PlPlayerController _player = PlPlayerController.getInstance();

  /// 随机播放的牌堆。空表示需要重新发牌。
  final List<String> _deck = <String>[];

  /// 随机历史的加载任务。首条播完可能早于历史读完，切换前先等它。
  Future<void>? _shuffleRestore;
  /// 历史已读完（或队列换过、历史已作废）后才允许在预取阶段补牌。
  bool _shuffleRestored = false;
  String _deckSignature = '';

  bool _opening = false;

  /// 加载期间在播放列表里点下的目标条目；当前 [_open] 收尾后补跳。
  ///
  /// 不加这个字段的话，`_opening` 为真时那次点击会被直接丢掉：列表页
  /// 已经 pop 掉了，用户看到列表关闭、视频却没换。
  int? _pendingOpenIndex;
  String? _pendingOpenSource;
  String? _error;

  /// 随机播放开关。和 [_repeat] 互斥展示：开着随机时按钮显示 shuffle，
  /// 播完从牌堆取；关掉后回到 [_repeat] 的五种模式之一。
  bool _shuffle = false;

  /// 播放模式，和 B 站 PlayRepeat 对齐。默认列表循环，保持旧版
  /// 「播完自动下一条、末尾回到第一条」的行为。
  PlayRepeat _repeat = PlayRepeat.listCycle;

  /// 播放模式落盘：0..4 对应 [PlayRepeat.index]，5 表示随机。
  static const String _playModeStoreKey = 'douyin.player.playMode';
  static const int _shufflePlayModeCode = 5;

  /// 只读诊断标志：只要有一次切条在途（open 中或列表点击已排队）就算真。
  bool get _switching => _opening || _pendingOpenIndex != null;

  /// 当前这条是否已经成功加载并起播。
  ///
  /// 每次 [_open] 主动切歌都先置 false，只有本次加载的数据源确认
  /// `loaded` 且 `play()` 成功后才重新置 true。旧媒体迟到的 `playing`
  /// 事件不会再把标记打开，避免一次点击后连续跳条。
  bool _completionArmed = false;

  /// [_open] 的会话号。异步加载期间如果又发生了新的切换，旧会话
  /// 不再有资格起播或上膛。
  int _openSession = 0;
  int _armedSession = -1;

  /// 状态监听只挂一次、只摘一次。
  bool _statusListening = false;

  /// 播过的 key。只用来让随机播放不重复，和「播放列表」是两回事。
  final Set<String> _played = <String>{};

  /// 是否点过小窗按钮。返回时要先把系统小窗关掉，否则页面退了自己还在后台播。
  bool _pipEntered = false;

  /// 是否已武装 iOS 自动画中画（播放中按 Home 自动起小窗）。
  bool _pipAutoArmed = false;

  /// 本次 arm 是否已显式请求原生启动 PiP。inactive / hidden / paused
  /// 会连续回调，只认第一次，避免重复下发。
  bool _pipStartRequested = false;

  /// 固定在实例上的回调引用，收尾时只清自己，避免误清下一个播放页。
  late final void Function() _pipAutoEnterHandler = _onPipAutoEnter;

  /// 后台保活。B站链路由 video 页写入 audio_service 的 mediaItem，
  /// `onUpdateState` 才会驱动 Now Playing / 音频会话；抖音页此前一条
  /// mediaItem 都没有，iOS 进后台后 Flutter texture 会被冻结，PiP 只能
  /// 反复显示最后一帧。这里复用现有的 audio_service，不新增依赖。
  late final String _bgTag =
      'douyin-short:${DateTime.now().microsecondsSinceEpoch}';
  bool _bgKeepAliveApplied = false;
  bool? _savedEnableBackgroundPlay;
  /// 本页是否已把 audio_service 的远程控制回调指向抖音播放器。
  /// 只在第一次进页时保存原值，切条复用，避免把「自己的包装」当成原值。
  bool _bgRemoteControlsBound = false;
  bool Function()? _savedBgIsPlaying;
  Future<void>? Function()? _savedBgOnPlay;
  Future<void>? Function()? _savedBgOnPause;
  Future<void>? Function(Duration position)? _savedBgOnSeek;
  void Function()? _savedBgOnSkipToNext;
  void Function()? _savedBgOnSkipToPrevious;
  int? _bgTextureId;

  /// 页面已经在退，避免重复触发。
  bool _leaving = false;

  /// 当前这次横向拖动累计的位移（像素）。用来判断「滑得够不够远」，
  /// 不依赖瞬时速度——慢速拖动也应该能返回。
  double _dragDx = 0;

  /// 视频层竖向手势当前调的是亮度还是音量。null 表示没在竖向拖动。
  _SwipeTarget? _swipeTarget;
  double _swipeStartY = 0;
  double _swipeStartValue = 0;

  /// 拖动时每像素对应多少比例；开始拖的时候算一次，避免每帧查 MediaQuery。
  double _swipeRange = 1;

  double _brightness = 1;
  double _volume = 1;
  bool _brightnessPrimed = false;
  bool _volumePrimed = false;

  /// 系统亮度不可写时退回应用亮度，退出播放页要把它复位。
  bool _brightnessIsApplication = false;

  /// 横向拖动的起点/预览目标，单位毫秒。
  int _seekStartMs = 0;
  int _seekTargetMs = 0;

  /// 开始横拖时缓存的屏宽，避免拖动途中每帧查 MediaQuery。
  double _seekWidth = 0;
  bool _seekDragging = false;

  /// 画面顺时针旋转的 90° 次数（0..3）。只旋转渲染层，不改原生屏幕方向。
  int _quarterTurns = 0;

  /// 画质/解码面板打开时一次性读到的当前流信息。
  ///
  /// 不在 build 里同步读 mpv：那是 FFI 调用，每帧读会把主 isolate 拖住。
  /// 只在用户点开对应面板时读一次，读不到就显示「未读到」。
  String? _qualityWidth;
  String? _qualityHeight;
  String _decodeCurrent = '';

  /// 当前已起播的媒体地址，供投屏使用；切条开始/失败时清空。
  String? _currentMediaUrl;
  String _currentMediaTitle = '';

  /// 画面填充：true = 裁剪铺满（BoxFit.cover），false = 适应（BoxFit.contain）。
  ///
  /// 用户反馈竖屏短视频上下黑边太大。默认开启裁剪铺满，让短边贴合屏幕
  /// 宽度；横屏内容在 [_videoFitFor] 里自动退回完整画面，避免裁掉两侧。
  /// 偏好落盘，下次进播放页沿用。
  bool _fillScreen = true;

  /// 「画面填充」偏好落盘键。true = 裁剪铺满，false = 适应。
  static const String _videoFitStoreKey = 'douyin.player.videoFit';

  /// 控件是否显示。和 B 站播放页一致：点一下画面切换沉浸式。
  ///
  /// 沉浸式下顶部条、底部条整块隐藏（不是变透明），同时视频区扩展到全屏。
  bool _chromeVisible = true;

  /// 进页面后自动隐藏控件的计时器，和 B 站播放页的隐藏行为对齐。
  Timer? _chromeTimer;

  /// Android PiP 精简布局：只留视频画面，不渲染标题/文案条。
  /// 只在原生进入/退出回调时 setState 一次，PiP 期间不做逐帧重绘。
  bool _isPipLayout = false;

  /// 进入 PiP 前的控件可见状态，退出时原样恢复。
  bool _chromeVisibleBeforePip = true;

  /// 上次下发的 PiP 遥控键状态签名，避免同一状态重复走 JNI。
  int? _pipActionSig;

  /// 播放页内嵌面板。评论 / 画质 / 更多都走这一层，不再开 Navigator 路由：
  /// 这条页面是 `Get.to` 推进来的，`showModalBottomSheet` / `PopupMenuButton`
  /// 生成的 overlay 在 iOS 真机上点开看不到（表现为「按钮按不动」）。
  _PlayerPanel? _panel;

  /// 评论面板的数据。key 用来判断是不是同一条视频，切条后旧结果作废。
  List<ShortVideoComment> _comments = const [];
  bool _commentsLoading = false;
  String _commentsError = '';
  String _commentsKey = '';
  int _commentsSession = 0;

  /// 评论面板顶部的视频文案默认展开，点一下折叠。
  bool _commentCaptionExpanded = true;

  /// 首屏评论缓存：`platform:videoId` -> 已返回的结果。
  ///
  /// 评论要走原生离屏网页，通常 5-20 秒。视频一打开就后台预取，面板打开
  /// 或切回同一视频时直接命中；用页面级静态缓存，页面重建后也不用再开网页。
  /// 只缓存有结果的页（含确认无评论），网络/风控失败留给面板手动重试。
  static final Map<String, _CommentPage> _commentCache =
      <String, _CommentPage>{};

  /// 正在进行的评论请求，按 `platform:videoId` 去重。
  ///
  /// 预取和面板打开撞到同一条视频时共享同一个 Future，不开第二个网页。
  static final Map<String, Future<_CommentPage>> _commentRequests =
      <String, Future<_CommentPage>>{};

  /// 评论缓存有效期，和 `ShortVideoWeb` 的十分钟缓存保持一致。
  static const int _commentCacheTtlMs = 10 * 60 * 1000;

  /// 评论缓存条数上限，连播几十条也不让 Map 无限增长。
  static const int _maxCommentCacheEntries = 24;

  /// 同时进行的评论预取上限：每次都会开一个离屏 WKWebView，快速连播时
  /// 不能无限叠加和播放抢 CPU。面板手动打开不受这个限制。
  static const int _maxCommentPrefetchInFlight = 3;

  /// 首屏只取第一页，先让用户看到约 20 条，不再等全量。
  static const int _commentsFirstPageLimit = 20;

  /// 亮度/音量/进度提示只重建这一小块，拖动时不用 setState 整页。
  final ValueNotifier<_GestureHint?> _gestureHint =
      ValueNotifier<_GestureHint?>(null);
  Timer? _gestureHintTimer;

  /// 播放状态单独驱动暂停/播放图标。
  ///
  /// playerStatus 是控制器上的普通字段，不是 Rx；以前每次播放/暂停都靠
  /// `setState(() {})` 刷整页，切条和高频状态回调叠加时会放大主 isolate
  /// 的重建量。这里只重建图标这一小块。
  final ValueNotifier<bool> _isPlaying = ValueNotifier<bool>(false);

  /// 下一条地址的预热：key + 进行中的解析任务。
  ///
  /// 自动连播的黑屏只有声音，主要是「上一条播完才开始解析下一条」。在本条
  /// 起播成功后提前解析下一条，`_open` 命中时直接拿结果。
  String? _prefetchKey;
  Future<QueueMedia?>? _prefetchFuture;

  /// 上一次 position 回调的墙钟时间，用来量化主 isolate 冻结。
  int _lastPositionTickMs = 0;

  /// 进度条专用局部状态。
  ///
  /// position/ duration / buffered 原来分别挂在 Obx 上，每个 position 回调
  /// 都会把控件树里的进度条和时间文本标脏。这里合并成一个 ValueNotifier，
  /// 按 200ms 节流后只刷这两个小部件，position 回调本身不再触发整页重建。
  final ValueNotifier<_PlaybackProgress> _progress =
      ValueNotifier<_PlaybackProgress>(const _PlaybackProgress());
  int _lastProgressPushMs = 0;

  /// 首帧看门狗。每次 open 起播后挂一次，超时没有首帧就整实例重建。
  Timer? _firstFrameWatchdog;
  int _watchdogSession = -1;
  int _watchdogIndex = -1;
  String _watchdogSource = 'auto';
  /// 这次 open 实际请求的 hwdec，供看门狗判断还能不能回滚 auto-copy。
  String _watchdogHwdec = _hwdec;
  /// 这次看门狗对应的条目 key；回滚只认当前这一条。
  String _watchdogKey = '';
  int _watchdogStartedAtMs = 0;
  bool _watchdogGraceUsed = false;
  int _watchdogOpenBusyRetries = 0;
  int _openStartPositionMs = 0;
  bool _firstFrameSeen = false;
  bool _recovering = false;
  int _autoRecoverCount = 0;
  int _recoverStreak = 0;

  /// 连续拿不到首帧的条目数（跨条目累计）。
  ///
  /// 成功看到首帧或用户手动选播时清零；到 [_maxConsecutiveSkip] 就停下
  /// 并给出可见提示，避免片源整体失效时整页无限乱跳。
  int _skipStreak = 0;

  /// 已经为哪些 B 站条目重新解析过 playurl。
  ///
  /// 按条目 key 只重试一次：随机/循环再转回同一条时不再重试，
  /// 保证「重试一次」不会变成死循环。
  final Set<String> _biliPlayurlRetried = <String>{};

  /// B 站首帧超时重开后，是否真正走到了「已起播、等首帧」阶段。
  ///
  /// 只给 [_retryBiliWithFreshPlayurl] 判断重开是不是在解析/加载阶段就
  /// 已经失败；失败时直接跳下一条，不等看门狗。
  bool _biliRetryOpenSucceeded = false;

  /// 本次 open 是否在解析阶段就没拿到地址。
  ///
  /// 跳过链（source=skip）要靠它继续往后跳：这种失败不会起播，也就不会
  /// 挂首帧看门狗，不能停在错误页上不动。其余失败（共享播放器、释放失败
  /// 等）不置位，避免把别人的占用误判成片源问题。
  bool _openMediaMissing = false;

  /// 开流初期观察 hwdec-current 的节拍器。首帧出现或超窗就停，
  /// 不让同步 FFI 读属性变成常驻采样。
  Timer? _hwdecProbeTimer;
  int _hwdecProbeStartedAtMs = 0;
  int _hwdecNoSinceMs = 0;

  /// 已经回滚成 auto-copy 的条目 key。
  ///
  /// 按条目 sticky：同一条只回滚一次（含后续自愈重建、再次播到同一条），
  /// 换到别的条目仍从直通 auto 起，绝不会在 auto / auto-copy 之间来回循环。
  /// 用户在播放列表里手动重选该条会清掉标记，允许重新尝试直通。
  final Set<String> _hwdecFallbackKeys = <String>{};

  /// 回滚标记上限：连播几百条也不让这个 Set 无限长；超了淘汰最早的一条，
  /// 被淘汰的条目下次播到会重新尝试一次 auto（仍只回滚一次，不会循环）。
  static const int _maxHwdecFallbackKeys = 200;

  /// 自动连播（复用同一 texture）累计条数；每 [_autoRebuildInterval] 条
  /// 主动整实例重建一次，避免 texture/解码器长期复用累积劣化。
  int _autoPlaysSinceRebuild = 0;

  /// 当前这次 [_open] 的起点，用来识别卡住的 opening 标志。
  int _openStartedAtMs = 0;

  /// 当前真正持有 `_opening` 的会话号。
  ///
  /// 被新请求作废的旧 open 仍可能在 await 里；它收尾时不能把新 open 的
  /// `_opening` 清掉，也不能替新 open 消费 pending。
  int _activeOpenSession = -1;

  /// open 在途超过这个时长就视为卡死；下一次切条先复位标志再继续。
  static const int _staleOpenMs = 12000;

  /// 看门狗撞上「本次 open 还没返回」时最多让路几次。
  ///
  /// 每次让路 1 秒；超过这个次数说明 open 自己卡住了，再等也不会等到首帧，
  /// 继续挂定时器只会无限自旋。此时停表并留日志，等下一次用户切条按
  /// [_staleOpenMs] 复位。
  static const int _maxWatchdogOpenBusyRetries = 8;

  /// 首帧看门狗首次检查的时点。常规首帧 ~2s 出，给一点余量在 ~2.8s
  /// 判定；彻底不来时尽早重建恢复画面，不再让用户盯 8 秒黑屏。
  static const int _firstFrameWatchdogMs = 2800;

  /// 连续多少条拿不到首帧就停止自动跳过并提示。
  static const int _maxConsecutiveSkip = 3;

  /// B 站首帧总预算：6S 这类低内存老机型给 ~12s，其它机型 ~8s。
  ///
  /// 实现上仍保留 2800ms 的常规看门狗触发重试；重开后的看门狗按
  /// 「原始 open 起点 + 本预算」计算剩余时间，所以总耗时落在 8s / 12s
  /// 左右，而不是两次各等一遍完整预算。
  static int get _biliFirstFrameBudgetMs =>
      ShortVideoPerf.lowMemory ? 12000 : 8000;

  /// 重开后的看门狗剩余时间上限，防止预算计算出异常大的值。
  static const int _maxBiliFirstFrameBudgetMs = 12000;

  /// 自动连播每 N 条主动重建一次 player/texture。手动选播 = 完整重建
  /// 能恢复，说明重建有效；这里提前做，防止累积到黑屏才被动救。
  static const int _autoRebuildInterval = 20;

  /// 抖音 / TikTok 短视频默认走直通硬解（auto → VideoToolbox 零拷贝）。
  ///
  /// 之前写死 auto-copy（硬解带 CPU 拷贝），6S 上实测 p10 只有 0.16x，
  /// 表现和「网络慢」几乎一样；B 站播放页传的就是 auto，这里对齐。
  /// 个别片源/机型直通解不出画面时由 [_hwdecFallback] 兜底，不在这里写死。
  static const String _hwdec = 'auto';

  /// 直通硬解的保底：回到原来的「硬解 + CPU 拷贝」。
  ///
  /// 只在首帧看门狗超时，或 hwdec-current 提前掉到 `no`（回落软解）并持续
  /// 超过 [_hwdecNoFallbackMs] 时，对同一条 open 回滚一次。回滚后行为与
  /// 改前版本一致：`videotoolbox` 解不出来时还能回落软解保画面。
  static const String _hwdecFallback = 'auto-copy';

  /// 开流初期读 hwdec-current 的节拍与观察窗口。
  static const int _hwdecProbeIntervalMs = 600;
  static const int _hwdecProbeWindowMs = 12000;

  /// `hwdec-current` 连续为 `no` 这么久才回滚，避开解码器初始化的一两拍。
  static const int _hwdecNoFallbackMs = 1200;

  /// 播放健康采样节拍。只在播放中读 mpv 属性，5 秒一次，不做逐帧读取。
  static const int _healthSampleIntervalMs = 5000;

  /// 起播后观察吞吐的窗口。6S 等低内存机型在 8 秒时仍 <0.5x 才回滚。
  static const int _throughputWindowMs = 8000;
  static const double _throughputRatioFloor = 0.5;
  static const double _throughputFpsFloorRatio = 0.6;
  static const double _throughputFpsFloorWithoutSource = 15;
  static const int _throughputHighBitrateKbps = 4000;

  /// 5 秒健康采样：上一次采样的墙钟与 position，用来算真实推进比。
  Timer? _playbackHealthTimer;
  int _healthLastAtMs = 0;
  int _healthLastPositionMs = 0;

  /// 6S 低吞吐看门狗：每次 open 只观察一个 8 秒窗口。
  Timer? _throughputWatchdog;
  int _throughputIndex = -1;
  String _throughputKey = '';
  String _throughputSource = 'auto';
  String _throughputHwdec = _hwdec;
  int _throughputStartAtMs = 0;
  int _throughputStartPositionMs = 0;

  /// 已经提示过吞吐不足的条目，避免 Toast 反复弹。
  final Set<String> _throughputDegradedKeys = <String>{};

  /// 当前 open 的媒体体积/码率。只用于吞吐降级判断与取证，不参与正常播放。
  int? _currentMediaBytes;
  int? _currentMediaBitrateKbps;

  /// App 是否在前台。后台时看门狗只记日志，不做重建（原生 PiP 由 C23 处理）。
  bool _appPaused = false;

  /// App 是否真的退到了后台（paused / hidden）。
  ///
  /// `_appPaused` 还包含 inactive（下拉控制中心），不能拿它判定「PiP 即将
  /// 接管画面」；否则控制中心一开就会把页内画面压成黑底。这里单独记。
  bool _appInBackground = false;

  /// PiP 活跃时是否已把页内视频层压到最小。
  ///
  /// 不能彻底摘掉 `Texture`：这个 media_kit fork 的 mpv 渲染回调依赖
  /// Flutter 侧持续请求纹理，纹理没有消费者后小窗只能回放旧帧。置真后
  /// [_video] 用黑底 + 2×2 `Texture` 占位，画面不可见但仍按帧取 buffer，
  /// 也不给整页制造逐帧重绘。
  bool _pipFrameSuppressed = false;

  /// 回前台后等原生关闭 PiP 的有界轮询，让页内画面尽快恢复。
  Timer? _pipFrameWatch;

  /// `ui-block` 事件按 stage/step 限流，避免持续卡顿把日志刷爆。
  final Map<String, int> _uiBlockLoggedAt = <String, int>{};

  /// 画中画状态推送的节拍器。
  ///
  /// iOS 的 AVSampleBufferDisplayLayer 用 timebase 给每帧打 PTS，而原生
  /// timebase 只有收到带 position 的 update 才会推进。此前抖音页从不推送，
  /// timebase 停在 0，老机型会把后续帧当成重复帧，画中画卡在第一帧。
  Timer? _pipTicker;

  /// 上一次 ticker 触发的墙钟时间，用来量化 Dart 主 isolate 的卡顿。
  int _lastPipTickMs = 0;

  /// 上一次推给原生的非 position 状态签名。
  ///
  /// 非 PiP 时 position 会随解码不断变化，但原生拿不到 PiP 会话也用不上；
  /// 这里只比较播放/缓冲/时长/轻量模式等真正影响小窗的状态，避免
  /// 500ms ticker 空跑一次 method channel。
  int? _lastPipStateSig;

  /// PiP 轻量模式的本地镜像。持久化是异步的，开关回调若再从 DiagProbe
  /// 读值会和落盘抢时序；这里以本地值为准，再异步写回。
  late bool _pipLite = DiagProbe.pipLiteMode;

  /// 直接推 PiP 轻量模式，不改 `IOSPipHelper` 的公共签名。
  static const MethodChannel _pipChannel = MethodChannel(
    'com.example.piliplus/pip',
  );

  QueueEntry get _current => _queue[_index];

  String get _playModeLabel => _shuffle ? '随机播放' : _repeat.label;

  IconData get _playModeIcon {
    if (_shuffle) return Icons.shuffle;
    return _playModeIconFor(_repeat);
  }

  static IconData _playModeIconFor(PlayRepeat repeat) {
    return switch (repeat) {
      PlayRepeat.pause => Icons.pause_circle_outline,
      PlayRepeat.listOrder => Icons.format_list_numbered,
      PlayRepeat.singleCycle => Icons.repeat_one,
      PlayRepeat.listCycle => Icons.repeat,
      PlayRepeat.autoPlayRelated => Icons.play_circle_outline,
    };
  }

  Color get _playModeColor => !_shuffle && _repeat == PlayRepeat.listOrder
      ? Colors.white
      : Colors.lightBlueAccent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restorePlayMode();
    _restoreVideoFit();
    _attachPlayerListeners();
    _startPlaybackHealthSampler();
    _pushProgress(force: true);
    // 诊断包常开：会话摘要仍写进 Documents/diag_playback.log，但正常
    // 播放不再常驻采样，只在开流/首帧/异常/导出时各采一次。
    // 普通包头一行就会 return，不产生文件。
    DiagProbe.startSession();
    // 必须在 startSession 之后：会话起点会先把单例带进来的旧纹理按 carry
    // 登记，之后再改来源，才不会把上一条/别的页面留下的纹理错标成 douyin。
    _player.textureSource = 'douyin';
    IOSPipHelper.onAutoEnter = _pipAutoEnterHandler;
    if (Platform.isAndroid) {
      PiliAndroidHelper.setPictureInPictureModeListener(
        _onAndroidPipModeChanged,
      );
      // 页面若是在小窗里重建的，第一次 build 就要用精简布局。
      _isPipLayout = PiliAndroidHelper.isPipMode;
    }
    _syncFrameConsumer('init');
    // B 站首帧预算要按机型分档（6S 12s / 其它 8s）；这里只问一次原生内存，
    // 之后同步读 ShortVideoPerf.lowMemory，不在看门狗路径上 await。
    unawaited(ShortVideoPerf.ensureProbed());
    _scheduleChromeHide();
    unawaited(_primeBrightness());
    unawaited(_primeVolume());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_dumpViewHierarchy());
      unawaited(PiliRootScan.run());
      unawaited(_open(_index, source: 'initial'));
      _shuffleRestore = _restoreShuffle();
    });
  }

  /// 进播放页时把原生视图层级落盘到 Documents/ui_hierarchy.txt。
  ///
  /// 目的：用户报「整页点不动、返回不了」时，我们一直在 Dart 侧猜是哪一层
  /// 吃了事件。这份文件直接给出真实的 UIView 树——如果有一个不透明的原生
  /// 视图盖在 Flutter 渲染视图上面，或者 Flutter 视图本身尺寸是 0，一眼可见。
  ///
  /// 只在 DEBUG 之外的诊断包里保留：失败静默，绝不影响播放。
  Future<void> _dumpViewHierarchy() async {
    try {
      await const MethodChannel('piliplus/view_diag').invokeMethod('dump');
    } catch (_) {}
  }

  /// 监听只挂一次、只摘一次。首帧自愈会换掉 [_player]，必须用同一组
  /// 方法重新挂载，否则新播放器没有 position/status 回调，看门狗也就失效。
  void _attachPlayerListeners() {
    _player.addStatusLister(_onPlayerStatus);
    _statusListening = true;
    _player.addPositionListener(_onPositionTick);
    _isPlaying.value = _player.playerStatus.isPlaying;
  }

  void _detachPlayerListeners() {
    if (_statusListening) {
      _statusListening = false;
      try {
        _player.removeStatusLister(_onPlayerStatus);
      } catch (_) {}
    }
    try {
      _player.removePositionListener(_onPositionTick);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPipTicker();
    _pipFrameWatch?.cancel();
    _pipFrameWatch = null;
    _chromeTimer?.cancel();
    _commentsSession++;
    _firstFrameWatchdog?.cancel();
    _cancelThroughputWatchdog();
    _playbackHealthTimer?.cancel();
    _playbackHealthTimer = null;
    _cancelHwdecProbe();
    // 走到这里说明页面已经真的没了。不管是不是走 _leave() 出去的，都必须
    // 确保播放器被释放——否则那个单例会一直活着，下次进播放页拿到的就是
    // 一个「以为自己在播」的实例，画面/声音错位，小窗也留在后台。
    //
    // 注意不能写 `if (!_leaving)`：_leave() 会先置 _leaving = true 再 pop，
    // 于是这里永远跳过，播放器就漏了。用 _disposed 单独记一次。
    if (!_disposed) {
      unawaited(_shutdown(alreadyLeft: true));
    }
    _gestureHintTimer?.cancel();
    _gestureHint.dispose();
    _isPlaying.dispose();
    _progress.dispose();
    super.dispose();
  }

  /// 收尾是否已经执行过（避免 dispose 和 postFrame 回调各跑一次）。
  bool _disposed = false;

  /// 退出播放页前的收尾。先关系统小窗，再把播放器停掉并释放。
  ///
  /// 为什么必须做：小窗开着的时候播放器还活着，又没有任何页面在管它，
  /// 再点进收藏页播下一条就会拿到那个「以为自己在播」的单例，画面/声音错位，
  /// 再叠加一层没关掉的小窗，页面就彻底点不动了。
  ///
  /// [alreadyLeft] 表示调用方已经在 pop 之后了，这里不要再拦一次。
  Future<void> _shutdown({bool alreadyLeft = false}) async {
    // 已经跑过就直回：pop 后的 postFrame 回调与 dispose() 会各调一次，
    // 但收尾只能做一次（重复 dispose 单例会连带把下一次的实例搞坏）。
    if (_disposed) return;
    if (_leaving && !alreadyLeft) return;
    _leaving = true;
    _disposed = true;
    _pipFrameWatch?.cancel();
    _pipFrameWatch = null;
    _cancelThroughputWatchdog();
    _playbackHealthTimer?.cancel();
    _playbackHealthTimer = null;
    _disarmPipAutoEnter('shutdown');
    if (identical(IOSPipHelper.onAutoEnter, _pipAutoEnterHandler)) {
      IOSPipHelper.onAutoEnter = null;
    }
    if (Platform.isAndroid) {
      PiliAndroidHelper.clearPictureInPictureModeListener(
        _onAndroidPipModeChanged,
      );
    }
    _stopPipTicker();
    _prefetchKey = null;
    _prefetchFuture = null;
    _detachPlayerListeners();
    try {
      if (_pipEntered && IOSPipHelper.isActive) {
        IOSPipHelper.dispose();
        _pipEntered = false;
      }
    } catch (_) {}
    final disposeSw = Stopwatch()..start();
    var disposeOk = false;
    String? disposeError;
    try {
      // 单例的 dispose 会把 _instance 置空，下次进播放页重新 getInstance 拿到
      // 干净实例。前提是本页只在 dispose() 时做，绝不在 build 期间调用。
      _player.dispose();
      disposeOk = true;
    } catch (error) {
      disposeError = '$error';
    } finally {
      disposeSw.stop();
      DiagProbe.disposeResult(
        ok: disposeOk,
        error: disposeError,
        elapsedMs: disposeSw.elapsedMilliseconds,
      );
    }
    // 放在 dispose 之后：dispose 会上报最后一次 texture release，先 stop 就
    // 会把这条漏掉，session-summary 的 alive 峰值/收尾数会不准。
    DiagProbe.frontFramePulling = false;
    DiagProbe.pipFrameKeepAlive = false;
    DiagProbe.stop();
    // dispose() 会在 enableBackgroundPlay 仍为真时清掉 mediaItem；
    // 收尾后再恢复用户原来的开关，避免污染 B站配置。
    _releaseBackgroundKeepAlive();
    if (_brightnessIsApplication) {
      _brightnessIsApplication = false;
      try {
        await ScreenBrightnessPlatform.instance
            .resetApplicationScreenBrightness();
      } catch (_) {}
    }
  }

  void _leave() {
    // 只退一次：连点两下、或者按钮和右滑同时触发时，第二次不能再 pop 掉
    // 下面那一层（那会把首页也退掉）。
    if (_leaving) return;
    // 必须先置位再导航。`navigator.pop()` 会在同一个调用栈里回调
    // `PopScope.onPopInvokedWithResult`，而 `_shutdown()` 虽然是 async，
    // 函数体里却没有 await——它是一路同步跑到 `_player.dispose()` 才返回的。
    // 没置位时，这串原生调用会卡在 pop 内部，返回按钮照样像死了一样。
    // 置位后 PopScope 回调会直接返回，真正的收尾交给下面的 postFrame。
    _leaving = true;

    _disarmPipAutoEnter('leave');
    _stopPipTicker();
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      // 播放页压在首页或播放列表上：正常 pop，退场动画立刻开始。
      navigator.pop();
    } else {
      // 这条才是「返回没反应」的根因。
      //
      // 收藏页是 MainApp 里的一个 Tab，不是独立路由；播放页是用
      // `Get.off`（Navigator.pushReplacement）直接从首页路由换过来的，
      // 所以导航栈里只剩播放页一条。`NavigatorState.canPop()` 在只剩一条
      // 路由时恒为 false，上面那句 pop 什么都不会做——返回按钮和右滑都走
      // `_leave`，于是两条路一起失灵，只能杀 App。
      //
      // 被替换掉的首页路由已经销毁，栈里没有「上一页」可 pop；用首页的
      // 命名路由替换自己，把栈底重新变回 MainApp。`offNamed` 底层就是
      // `pushReplacementNamed`，旧路由要等新路由转场结束才 dispose，
      // 不会在这里同步跑播放器释放。
      unawaited(Get.offNamed<void>('/', preventDuplicates: false));
    }

    // 收尾推到下一帧：导航动作已经开始，原生 dispose 不会再挡住退场动画。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_shutdown(alreadyLeft: true));
    });
  }

  /// 把某一条解析成可以直接交给播放器的地址，然后开播。
  Future<void> _open(
    int index, {
    String source = 'auto',
    bool force = false,
    bool uncachedResolve = false,
    int? firstFrameDeadlineMs,
  }) async {
    if (_disposed || _leaving || _queue.isEmpty) {
      _diagSwitchBlocked(
        source,
        _queue.isEmpty ? 'empty-queue' : 'page-gone',
        targetIndex: index,
      );
      return;
    }
    final target = index.clamp(0, _queue.length - 1);
    // 切条请求不能因为上一次 open 还在途就被丢掉：用户点「下一条」或播放
    // 列表条目时，列表页已经关了，丢掉就等于这一下彻底没反应。这里排队，
    // 并把在途会话作废，让它跑到下一个检查点就退出，不再把用户不想要的那条
    // 播出来；真正的补跳在 finally 里执行。
    if (_recovering && !force) {
      _pendingOpenIndex = target;
      _pendingOpenSource = source;
      DiagProbe.event('switch-pending', <String, Object?>{
        'source': source,
        'targetIndex': target,
        'curIndex': _index,
        'reason': 'recovering',
        'isBuffering': _player.isBuffering.value,
      });
      return;
    }
    if (_opening) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final staleMs = _openStartedAtMs > 0 ? now - _openStartedAtMs : 0;
      if (staleMs > _staleOpenMs) {
        _opening = false;
        _openStartedAtMs = 0;
        DiagProbe.event('switch-blocked', <String, Object?>{
          'source': source,
          'reason': 'stale-opening-reset',
          'staleMs': staleMs,
          'targetIndex': target,
          'curIndex': _index,
          'switchingFlag': _switching,
          'isBuffering': _player.isBuffering.value,
        });
      } else {
        _pendingOpenIndex = target;
        _pendingOpenSource = source;
        _openSession++;
        _diagSwitchBlocked(
          source,
          'opening-deferred',
          targetIndex: target,
        );
        DiagProbe.event('switch-pending', <String, Object?>{
          'source': source,
          'targetIndex': target,
          'curIndex': _index,
          'msSinceOpen': _openStartedAtMs == 0 ? null : now - _openStartedAtMs,
          'isBuffering': _player.isBuffering.value,
        });
        return;
      }
    }
    final session = ++_openSession;
    _activeOpenSession = session;
    final fromIndex = _index;
    final switchingBefore = _switching;
    _openStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    _openStartPositionMs = _player.positionInMilliseconds;
    _resetPlaybackHealthWindow();
    if (source != 'auto-recover') _recoverStreak = 0;
    // B 站重试也属于失败处理链路，不能把连续失败计数清零。
    if (source == 'initial' ||
        source == 'next' ||
        source == 'previous' ||
        source == 'playlist-select') {
      _skipStreak = 0;
      _biliPlayurlRetried.remove(_queue[target].key);
    }
    _cancelFirstFrameWatchdog();
    _firstFrameSeen = false;
    _opening = true;
    _completionArmed = false;
    _openMediaMissing = false;
    // 开关日志：记录点击/自动连播真正进入 open 的瞬间。isBuffering 不是
    // 拦截条件，这里只把它作为证据写下来，方便对比「buffering 时点了也切」。
    DiagProbe.event('switch-now', <String, Object?>{
      'source': source,
      'targetIndex': target,
      'fromIndex': fromIndex,
      'isBuffering': _player.isBuffering.value,
      'playing': _player.playerStatus.isPlaying,
      'switchingFlag': switchingBefore,
      'pendingFlag': _pendingOpenIndex != null,
      'recovering': _recovering,
      'positionMs': _openStartPositionMs,
      'textureId': _player.videoController?.id.value,
    });
    String? openError;
    // 共享实例中止时不会走到 beginOpen，收尾时不能拿上一条遗留的 tracker
    // 去写 open-end，否则会多出一条错位的失败记录。
    var beganOpen = false;
    try {
      final entry = _queue[target];
      // 同一条如果已经因硬解失败回滚过，后续 open（含自愈重建）沿用
      // auto-copy；换到别的条目仍从直通 auto 起。
      final hwdec = _effectiveHwdecFor(entry.key);
      // 切条探针：旧 textureId 必须在 setDataSource 前取，否则拿到的已经
      // 是新纹理，无法判断「换了纹理但没画面」。
      final oldTextureId = _player.videoController?.id.value;
      // PiP 活跃时不再硬阻断切条：原生 PipSession 会把小窗 surface 留在旧
      // texture 的最后一帧上（surfaceHold），新实例注册 FlutterTexture 后
      // 自动 retarget，新首帧到达再解除 hold。唯一前提仍是独占本播放器
      // 实例——共享单例被别处持有时不能拆，交给下面的检查中止。
      final pipActive = IOSPipHelper.isActive;
      if (pipActive) {
        final allow = _player.canReleaseSolo;
        DiagProbe.event('pip-switch', <String, Object?>{
          'allow': allow,
          'reason': allow ? 'pip-retarget' : 'shared-player',
          'fromIndex': fromIndex,
          'toIndex': target,
          'oldTextureId': oldTextureId,
          'pipActive': pipActive,
          'playerCount': PlPlayerController.playerCount,
        });
      }
      // 共享单例被 B站/PiP 持有时不能拆：那会把别人的画面一起换掉。在改
      // _index 之前就判，直接中止本次切换并留证，避免「标题已是下一条、
      // 画面还在上一条」的错位。
      if (!_player.canReleaseSolo) {
        openError = 'shared-player';
        DiagProbe.event('switch-blocked', <String, Object?>{
          'source': source,
          'reason': 'shared-player',
          'targetIndex': target,
          'curIndex': fromIndex,
          'oldTextureId': oldTextureId,
          'playerCount': PlPlayerController.playerCount,
        });
        if (mounted) {
          setState(() => _error = '播放器正在别处使用，请稍后再试');
        }
        return;
      }
      DiagProbe.beginOpen(
        index: target,
        key: entry.key,
        oldTextureId: oldTextureId,
        source: source,
        hwdecRequested: hwdec,
      );
      beganOpen = true;
      DiagProbe.openPhase('resolve');
      setState(() {
        _index = target;
        _error = null;
        _resetComments();
      });
      // 视频一打开就在后台抓评论第一页，和媒体解析并行；不管评论面板
      // 有没有打开都发起，用户点开时才能直接命中或只等这个在途请求。
      _prefetchComments(source: source);
      // 评论面板开着时切条，旧结果已经作废，需要按新视频重新抓一次。
      if (_panel == _PlayerPanel.comments) {
        unawaited(_ensureComments());
      }
      _disarmPipAutoEnter('switch');
      // 必须先于 setDataSource/play：audio_service 只有在 _item 非空时
      // 才会真正写入后台播放状态。
      _applyBackgroundKeepAlive();
      // 抖音 / TikTok 的 CDN 按网页会话校验，必须带上 WKWebView 那罐 cookie，
      // 否则「地址解析出来了、一播就 403」。
      //
      // 但取 cookie 不能挡在开播前面：本地已经缓存好整条时，它是纯磁盘读取。
      // 之前无论本地有没有缓存，都先 await 一次 cookie（原生通道，网页没开过
      // 时是慢路径）再查缓存，串行下来就是「右下角都显示缓存 281MB 了，还要
      // 等很久」。现在先试离线，命中就直接开播，cookie 完全不碰。
      final resolveSw = Stopwatch()..start();
      final media = await _resolveMedia(entry, uncached: uncachedResolve);
      resolveSw.stop();
      _diagUiBlock(
        'open',
        'resolve',
        resolveSw,
        extra: <String, Object?>{'index': target},
      );
      if (!mounted || _disposed || _leaving || session != _openSession) {
        return;
      }
      if (media == null || media.url.isEmpty) {
        openError = 'no-media';
        _openMediaMissing = true;
        setState(() => _error = '解析不出播放地址');
        return;
      }
      // 自动连播会优先吃预取结果，手动选播通常重新解析；把来源与是否本地
      // 缓存写进日志，才能对比两条 open 路径拿到的媒体是否不同。
      _currentMediaBytes = null;
      _currentMediaBitrateKbps = null;
      if (media.isLocal) {
        try {
          final bytes = File(media.url).lengthSync();
          _currentMediaBytes = bytes;
          if (bytes > 0 && entry.durationMs > 0) {
            final seconds = entry.durationMs / 1000;
            _currentMediaBitrateKbps = (bytes * 8 / seconds / 1000).round();
          }
        } catch (_) {}
      }
      DiagProbe.event('open-media', <String, Object?>{
        'source': source,
        'index': target,
        'key': entry.key,
        'local': media.isLocal,
        'host': Uri.tryParse(media.url)?.host,
        'bytes': _currentMediaBytes,
        'bitrateKbps': _currentMediaBitrateKbps,
        'durationMs': entry.durationMs,
        'hwdecRequested': hwdec,
      });
      // 切条必须在开新流前把旧 Player 连同 FlutterTexture 一起拆掉。
      //
      // build67 诊断里，同一条 texture 连播 20+ 条后，下一次 open 的
      // video-params/w 要等 20s+ 才出现，hwdec-current 从 videotoolbox 掉到
      // no，position 冻在换源前。这是 mpv 在同一上下文反复换源、VideoToolbox
      // 解码器重建失败且旧 FlutterTexture 不释放的典型表现。B 站页面每次进入
      // 都是新单例，不存在长期复用同一条纹理，所以这里也要在换源前断开。
      //
      // 共享单例与 PiP 已在改 _index 前判过，这里只需执行拆旧纹理。
      if (oldTextureId != null) {
        // resolve 是网络 await，期间别的页面仍可能 getInstance 把单例抬成
        // 共享。真正拆之前再确认一次独占：不等独占就中止，绝不拆别人的
        // 画面（C51D review 2 的硬约束）。
        if (!_player.canReleaseSolo) {
          openError = 'shared-player';
          DiagProbe.event('switch-blocked', <String, Object?>{
            'source': source,
            'reason': 'shared-player',
            'phase': 'pre-release',
            'targetIndex': target,
            'curIndex': fromIndex,
            'oldTextureId': oldTextureId,
            'playerCount': PlPlayerController.playerCount,
          });
          if (mounted) {
            setState(() {
              _index = fromIndex;
              _error = '播放器正在别处使用，请稍后再试';
            });
            if (_panel == _PlayerPanel.comments) {
              unawaited(_ensureComments());
            }
          }
          // 上一步已经按 target 写过后台播放卡片，这里退回上一条要同步。
          _applyBackgroundKeepAlive();
          return;
        }
        final releaseSw = Stopwatch()..start();
        DiagProbe.openPhase('release-texture');
        _detachPlayerListeners();
        try {
          await _player.releaseTexture(reason: 'switch');
        } catch (error) {
          // 只有 native dispose 成功才算旧纹理没了。失败时 releaseTexture
          // 保留原实例并上报 release-failed，这里必须整体中止：继续
          // setDataSource 会让旧纹理和解码器叠在新流下面。
          releaseSw.stop();
          _diagUiBlock(
            'open',
            'release-texture',
            releaseSw,
            extra: <String, Object?>{
              'index': target,
              'oldTextureId': oldTextureId,
              'error': '$error',
            },
          );
          DiagProbe.event('switch-blocked', <String, Object?>{
            'source': source,
            'reason': 'release-failed',
            'targetIndex': target,
            'curIndex': fromIndex,
            'oldTextureId': oldTextureId,
            'error': '$error',
          });
          openError = 'release-failed';
          _attachPlayerListeners();
          if (mounted) {
            setState(() {
              _index = fromIndex;
              _error = '切换失败：旧播放器未能释放';
            });
            if (_panel == _PlayerPanel.comments) {
              unawaited(_ensureComments());
            }
          }
          _applyBackgroundKeepAlive();
          return;
        }
        _player = PlPlayerController.getInstance();
        _player.textureSource = 'douyin';
        _attachPlayerListeners();
        releaseSw.stop();
        _diagUiBlock(
          'open',
          'release-texture',
          releaseSw,
          extra: <String, Object?>{
            'index': target,
            'oldTextureId': oldTextureId,
          },
        );
        if (!mounted || _disposed || _leaving || session != _openSession) {
          return;
        }
      }
      // 抖音 / TikTok 的 CDN 认网页 UA 和 referer，上游 controller 里默认写死了
      // 桌面 UA + B 站 referer，直接用会 403 或者只给到一部分数据（表现为
      // 「有声音没画面」）。这里在开播前把 header 换成本条自己的来源。
      //
      // 本地文件一律清成上游默认（传 null 恢复）。本地命中时没有 CDN 参与，
      // 留着上一条抖音的 UA/referer 纯属脏状态。
      if (!media.isLocal) {
        _player.overrideMediaHeader(
          userAgent: media.userAgent.isEmpty ? null : media.userAgent,
          referer: media.referer.isEmpty ? null : media.referer,
        );
      } else {
        _player.overrideMediaHeader();
      }
      // 切源开始后旧地址就失效了：在起播成功前，投屏入口不能还指向
      // 上一条。等 play() 成功后再写回本条地址。
      _currentMediaUrl = null;
      DiagProbe.openPhase('set-datasource');
      final sourceSw = Stopwatch()..start();
      await _player.setDataSource(
        // 缓存好的那条是磁盘上的 mp4，必须按本地文件打开，不能当网络源。
        //
        // 传 NetworkSource 会让 controller 走 `initBuffer()` 那套网络分支，
        // 下发 `cache=yes` + `demuxer-max-bytes`（默认几十 MB）。mpv 拿到一个
        // 普通本地路径却被要求开网络缓存，会先按网络流探测、分配流缓存，然后
        // 才回落到本地文件打开——这就是「已经缓存了几百 MB，起播还是要等很久」
        // 的直接原因。
        //
        // 不能硬套上游的 FileSource：它把路径写死成 `dir/typeTag/0.mp4`，
        // 是 B 站下载目录的结构，我们是 `short_video/douyin_123.mp4` 单文件。
        // 所以这里传路径本身，再让 controller 按「本地文件」处理
        // （见 setDataSource 的 isLocalFile 参数）。
        NetworkSource(videoSource: media.url, audioSource: null),
        autoplay: true,
        isVertical: true,
        isLocalFile: media.isLocal,
        // 抖音 / TikTok 默认走直通硬解（auto），只有已回滚过的条目才用
        // auto-copy；本地缓存同样要解码，显式打开，不依赖全局硬解开关。
        hwdecOverride: hwdec,
        enableHardwareAcceleration: true,
        // 本地文件时长已知，直接告诉播放器，省掉一次探测。
        duration: media.isLocal && entry.durationMs > 0
            ? Duration(milliseconds: entry.durationMs)
            : null,
      );
      sourceSw.stop();
      _diagUiBlock(
        'open',
        'setDataSource',
        sourceSw,
        extra: <String, Object?>{'index': target, 'local': media.isLocal},
      );
      // 切条复用同一个 FlutterTexture 时 same=YES；这条用来证明没有因为
      // 换源把整页 texture 重建掉。
      final newTextureId = _player.videoController?.id.value;
      DiagProbe.event('texture-reuse', <String, Object?>{
        'same': newTextureId != null && newTextureId == oldTextureId,
        'oldTextureId': oldTextureId,
        'newTextureId': newTextureId,
      });
      if (!mounted || _disposed || _leaving || session != _openSession) {
        return;
      }
      // `setDataSource(autoplay: true)` 内部的自动播放走的是静态
      // `playIfExists()`，只有 B 站视频页 / 直播页注册了那个回调。
      // 抖音页没有注册，只加载不会真正播放，这里在确认数据源就绪后
      // 显式起播；首条和自动切出的下一条都会经过这里。
      if (_player.dataStatus.value != DataStatus.loaded) return;
      DiagProbe.openPhase('play');
      final playSw = Stopwatch()..start();
      await _player.play();
      playSw.stop();
      _diagUiBlock(
        'open',
        'play',
        playSw,
        extra: <String, Object?>{'index': target},
      );
      if (!mounted || _disposed || _leaving || session != _openSession) {
        return;
      }
      // 听音频是页面级开关，切到下一条后新的 file-local-options 会重置；
      // 保持用户的选择，不让画面偷偷恢复。
      if (_player.onlyPlayAudio.value) {
        try {
          _player.videoPlayerController?.setProperty(
            'file-local-options/vid',
            'no',
          );
        } catch (_) {}
      }
      _publishPipState();
      _armPipAutoEnter('open');
      _completionArmed = true;
      _armedSession = session;
      _armFirstFrameWatchdog(
        session: session,
        index: target,
        source: source,
        hwdec: hwdec,
        deadlineMs: firstFrameDeadlineMs,
      );
      _armThroughputWatchdog(
        session: session,
        index: target,
        source: source,
        hwdec: hwdec,
      );
      if (source == 'bili-retry') _biliRetryOpenSucceeded = true;
      _pushProgress(force: true);
      DiagProbe.openPhase('played');
      DiagProbe.playItem(key: entry.key);
      _isPlaying.value = _player.playerStatus.isPlaying;
      _notePlayed(entry.key);
      // 只统计自动连播（复用同一 texture）的条数；手动切播/自愈重建不计数。
      if (source == 'auto') _autoPlaysSinceRebuild++;
      _prefetchNext();
      // videoController 是本次 setDataSource 才建出来的，必须重建一次把
      // 加载圈换成画面。这是一次切换一次，不是按帧刷新。
      //
      // 顺手记下本条的网络地址给投屏用；本地缓存是磁盘路径，不能投递，
      // 保持为空，投屏按钮会明确提示而不是把本地路径当直链发出去。
      if (mounted) {
        setState(() {
          _currentMediaUrl = media.isLocal ? null : media.url;
          _currentMediaTitle = entry.title;
        });
      }
    } catch (error) {
      openError = '$error';
      _currentMediaUrl = null;
      if (mounted) setState(() => _error = '播放失败：$error');
    } finally {
      if (beganOpen) {
        DiagProbe.endOpen(error: openError);
      }
      // 只有仍然持有 `_opening` 的会话才有资格收尾。被新请求作废的旧
      // open 可能刚醒过来，不能把新 open 的标志清掉、也不能替它消费
      // pending，否则新 open 会立刻被当成「已结束」而丢状态。
      if (_activeOpenSession == session) {
        _activeOpenSession = -1;
        _opening = false;
        _openStartedAtMs = 0;
        // 自愈的 open 收尾时仍处于 recovery 中，交给 recovery 的 finally
        // 消费 pending；否则这里同步再 open 会被 `_recovering` 二次排队。
        if (!_recovering) _consumePendingOpen();
      }
    }
  }

  /// 补跳加载期间用户点下的目标。列表页此时已经关闭，丢一次就完全没反应。
  void _consumePendingOpen() {
    final pending = _pendingOpenIndex;
    if (pending == null) return;
    final pendingSource = _pendingOpenSource ?? 'auto';
    _pendingOpenIndex = null;
    _pendingOpenSource = null;
    if (!mounted || _leaving || _disposed) return;
    unawaited(_open(pending, source: pendingSource));
  }

  void _diagSwitchRequest(String source, int targetIndex) {
    DiagProbe.event('switch-request', <String, Object?>{
      'source': source,
      'targetIndex': targetIndex,
      'curIndex': _index,
      'switchingFlag': _switching,
      'openingFlag': _opening,
      'isBuffering': _player.isBuffering.value,
      'playing': _player.playerStatus.isPlaying,
      'positionMs': _player.positionInMilliseconds,
      'durationMs': _player.durationInMilliseconds,
      'queueLen': _queue.length,
      'textureId': _player.videoController?.id.value,
      'msSincePageStart': DiagProbe.sessionElapsedMs,
    });
  }

  void _diagSwitchBlocked(
    String source,
    String reason, {
    int? targetIndex,
  }) {
    DiagProbe.event('switch-blocked', <String, Object?>{
      'source': source,
      'reason': reason,
      'targetIndex': targetIndex,
      'curIndex': _index,
      'switchingFlag': _switching,
      'openingFlag': _opening,
      'isBuffering': _player.isBuffering.value,
    });
  }

  /// 主 isolate 计时探针：一次同步工作超过 50ms 就写一条 `ui-block`，
  /// 让下一份诊断包直接指出是 open / position / gesture 哪一段堵住。
  ///
  /// [throttleMs] 用于 position/gesture 这种每秒会回调多次的阶段，
  /// 避免持续卡顿时同一条事件把日志刷爆；open 各阶段每次只发生一次，
  /// 默认不限流。
  void _diagUiBlock(
    String stage,
    String step,
    Stopwatch sw, {
    Map<String, Object?> extra = const {},
    int throttleMs = 0,
  }) {
    final ms = sw.elapsedMilliseconds;
    if (ms < 50) return;
    if (throttleMs > 0) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final key = '$stage:$step';
      final last = _uiBlockLoggedAt[key] ?? 0;
      if (now - last < throttleMs) return;
      _uiBlockLoggedAt[key] = now;
    }
    DiagProbe.event('ui-block', <String, Object?>{
      'stage': stage,
      'step': step,
      'ms': ms,
      ...extra,
    });
  }

  /// position 流每来一次就同步刷新播放状态，并量化两次回调之间的空洞。
  ///
  /// 主 isolate 被整块堵住时，正常 100~500ms 一次的 position 回调会出现
  /// 秒级间隔；这里把 gap 直接写进 `ui-block`，不依赖 ticker 的 500ms 节拍。
  void _onPositionTick(Duration position) {
    if (_disposed) return;
    final sw = Stopwatch()..start();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final gapMs = _lastPositionTickMs == 0 ? 0 : nowMs - _lastPositionTickMs;
    _lastPositionTickMs = nowMs;
    final isPlaying = _player.playerStatus.isPlaying;
    if (_isPlaying.value != isPlaying) {
      _isPlaying.value = isPlaying;
    }
    // 进度只推给底部那一小块 ValueListenableBuilder，不再让整个页面或
    // Obx 子树跟着 position 回调重建。
    // 首帧判定放在看门狗里做：它要读一次 mpv 属性（同步 FFI），不能塞进
    // 每秒多次的 position 回调，否则又会把主 isolate 堵住。
    _pushProgress();
    sw.stop();
    _diagUiBlock(
      'position',
      'tick',
      sw,
      extra: <String, Object?>{'positionMs': position.inMilliseconds},
      throttleMs: 1000,
    );
    // 回调本身很快，但两次回调间隔很大，说明主 isolate 在此之前被整块
    // 占住了。这条不能按 50ms 的同步耗时判断，单独记 gap。
    if (gapMs > 1000) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = _uiBlockLoggedAt['position:gap'] ?? 0;
      if (now - last >= 1000) {
        _uiBlockLoggedAt['position:gap'] = now;
        DiagProbe.event('ui-block', <String, Object?>{
          'stage': 'position',
          'step': 'gap',
          'ms': gapMs,
          'positionMs': position.inMilliseconds,
        });
      }
    }
  }

  void _startPlaybackHealthSampler() {
    _playbackHealthTimer?.cancel();
    _playbackHealthTimer = null;
    // 纯诊断的 5s 全量采样在 diag 关闭时不应存在；吞吐看门狗有自己的
    // 功能性采样，不依赖这个定时器。
    if (!kDiagEnabled) return;
    _playbackHealthTimer = Timer.periodic(
      const Duration(milliseconds: _healthSampleIntervalMs),
      (_) => _samplePlaybackHealth(),
    );
  }

  void _resetPlaybackHealthWindow() {
    _healthLastAtMs = 0;
    _healthLastPositionMs = 0;
  }

  /// 5 秒一次的低频健康采样。
  ///
  /// 只有这里和吞吐看门狗会同步读 mpv 属性；position 回调保持零 FFI。
  /// 采样会同时判断上 5 秒的 position 推进比，推进不足就写成 `slow-sample`，
  /// 让「能出画面但吞吐极低」的条目也有 hwdec/分辨率/帧率/缓存可对照。
  void _samplePlaybackHealth() {
    if (!kDiagEnabled) return;
    if (_disposed || _leaving || !mounted) return;
    if (_queue.isEmpty || _index < 0 || _index >= _queue.length) return;
    if (_opening || _recovering || _pendingOpenIndex != null) return;
    if (_player.dataStatus.value != DataStatus.loaded ||
        !_player.playerStatus.isPlaying) {
      _resetPlaybackHealthWindow();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final position = _player.positionInMilliseconds;
    final wallMs = _healthLastAtMs == 0 ? 0 : now - _healthLastAtMs;
    final advanceMs = _healthLastAtMs == 0
        ? 0
        : position - _healthLastPositionMs;
    _healthLastAtMs = now;
    _healthLastPositionMs = position;
    final ratio = wallMs > 0 ? advanceMs / wallMs : null;
    final slow =
        wallMs >= 2000 &&
        advanceMs >= 0 &&
        ratio != null &&
        ratio < _throughputRatioFloor;
    final inPip = IOSPipHelper.isActive;
    final tag = slow
        ? 'slow-sample'
        : (inPip ? 'pip-frame-health' : 'frame-health');
    DiagProbe.playbackSample(
      tag,
      extra: <String, Object?>{
        'source': 'dart',
        'index': _index,
        'key': _current.key,
        'wallMs': wallMs,
        'positionAdvanceMs': advanceMs,
        'positionRatio': ratio,
        'buffering': _player.isBuffering.value,
        'hwdecRequested': _effectiveHwdecFor(_current.key),
        'mediaBytes': _currentMediaBytes,
        'mediaBitrateKbps': _currentMediaBitrateKbps,
        'reason': slow ? 'low-position-ratio' : null,
      },
    );
  }

  /// 把 position / duration / buffered 合并成一个低节拍的局部状态。
  ///
  /// position 回调一秒可能来好几次，直接逐次刷 widget 会把进度条和时间
  /// 文本反复标脏；这里 200ms 节流，并且只在秒级数值变化时通知。
  void _pushProgress({bool force = false}) {
    if (_disposed || !mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastProgressPushMs < 200) return;
    _lastProgressPushMs = now;
    final total = _player.duration.value;
    final position = total <= 0
        ? 0
        : _player.position.value.clamp(0, total).toInt();
    final buffered = total <= 0
        ? 0
        : _player.buffered.value.clamp(0, total).toInt();
    final next = _PlaybackProgress(
      position: position,
      duration: total,
      buffered: buffered,
    );
    if (next != _progress.value) {
      _progress.value = next;
    }
  }

  /// 直接读 mpv 的视频轨宽度。
  ///
  /// 不能用 `state.width`：连播复用同一个 texture 时，它可能还是上一条的
  /// 宽高，会把「有声音没画面」误判成已经有首帧。mpv 的 `video-params/w`
  /// 在新文件解出视频轨前为空，正好对应真机日志里的 no-first-frame。
  int? _mpvVideoWidth() {
    try {
      final raw = _player.videoPlayerController?.getProperty('video-params/w');
      if (raw == null || raw.isEmpty) return null;
      final width = num.tryParse(raw);
      if (width == null || width <= 0) return null;
      return width.toInt();
    } catch (_) {
      return null;
    }
  }

  /// 首帧判定：起播位置在走，且 mpv 已经识别出视频轨。
  ///
  /// 会做一次同步 FFI 读取，只允许在看门狗和短窗口 hwdec 探针（低频）里
  /// 调用，不能放进每秒多次的 position 回调。
  bool _hasFirstFrameNow() {
    if (_player.dataStatus.value != DataStatus.loaded) return false;
    if (_player.positionInMilliseconds <= 0) return false;
    return (_mpvVideoWidth() ?? 0) > 0;
  }

  /// 当前条目实际应该请求的 hwdec。
  ///
  /// 只有「这一条已经回滚过」时才用 auto-copy；其余一律直通 auto。
  String _effectiveHwdecFor(String key) {
    if (key.isEmpty) return _hwdec;
    return _hwdecFallbackKeys.contains(key) ? _hwdecFallback : _hwdec;
  }

  String? _readHwdecCurrent() {
    try {
      final raw = _player.videoPlayerController?.getProperty('hwdec-current');
      if (raw == null || raw.isEmpty) return null;
      return raw;
    } catch (_) {
      return null;
    }
  }

  static num? _numOf(Object? value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  /// 起播后短窗口内观察 hwdec-current；已经请求 auto-copy 的 open 不再观察。
  void _armHwdecProbe(String hwdec) {
    _cancelHwdecProbe();
    if (hwdec == _hwdecFallback) return;
    _hwdecProbeStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    _hwdecProbeTimer = Timer.periodic(
      const Duration(milliseconds: _hwdecProbeIntervalMs),
      (_) => _pollHwdecCurrent(),
    );
  }

  void _cancelHwdecProbe() {
    _hwdecProbeTimer?.cancel();
    _hwdecProbeTimer = null;
    _hwdecProbeStartedAtMs = 0;
    _hwdecNoSinceMs = 0;
  }

  /// hwdec-current 掉到 `no` 且持续超过 [_hwdecNoFallbackMs] 就回滚一次。
  ///
  /// 探针只在两种情况下收工：读到真实硬件解码器（videotoolbox / \*-copy），
  /// 或 [_hwdecProbeWindowMs] 观察窗口到期。首帧出现不算数——直通失败但
  /// mpv 回落软解时画面照样能出，这正是要回滚 auto-copy 的场景。
  /// 暂停 / 后台 / PiP / buffering 一律放过，避免把用户主动暂停或小窗正在
  /// 用的纹理拆掉。
  void _pollHwdecCurrent() {
    if (_disposed || _leaving) {
      _cancelHwdecProbe();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_hwdecProbeStartedAtMs == 0 ||
        now - _hwdecProbeStartedAtMs > _hwdecProbeWindowMs) {
      _cancelHwdecProbe();
      return;
    }
    if (_opening || _recovering || _pendingOpenIndex != null) {
      _hwdecNoSinceMs = 0;
      return;
    }
    if (_appPaused || IOSPipHelper.isActive || _player.isBuffering.value) {
      _hwdecNoSinceMs = 0;
      return;
    }
    // 用户主动暂停在首帧之前不是解码问题；和看门狗一样让路，
    // 恢复播放后 _togglePlay 会重新挂看门狗与探针。
    if (!_player.playerStatus.isPlaying) {
      _hwdecNoSinceMs = 0;
      return;
    }
    if (_player.dataStatus.value != DataStatus.loaded) {
      _hwdecNoSinceMs = 0;
      return;
    }
    final current = _readHwdecCurrent();
    // 落到真实硬件解码器就说明直通成功，停掉探针，别给主 isolate 添读操作。
    if (_isHwdecHardware(current)) {
      _cancelHwdecProbe();
      return;
    }
    // 还没定下来（null / auto 之类的请求名）就继续等。
    if (current != 'no') {
      _hwdecNoSinceMs = 0;
      return;
    }
    if (_hwdecNoSinceMs == 0) {
      _hwdecNoSinceMs = now;
      return;
    }
    if (now - _hwdecNoSinceMs < _hwdecNoFallbackMs) return;
    _fallbackToAutoCopy(
      reason: 'hwdec-current-no',
      index: _watchdogIndex,
      source: _watchdogSource,
      elapsedMs: now - _hwdecProbeStartedAtMs,
      elapsedFrom: 'hwdec-probe',
    );
  }

  /// hwdec-current 是否已经是真实硬件解码器。
  ///
  /// mpv 在解码器定下来之前可能回 `auto` / `auto-safe` 这类请求名，这些
  /// 都不算成功，继续观察；`no` 是回落软解，交给回滚逻辑。
  static bool _isHwdecHardware(String? current) {
    if (current == null || current.isEmpty) return false;
    if (current == 'no' || current.startsWith('auto')) return false;
    return true;
  }

  void _armFirstFrameWatchdog({
    required int session,
    required int index,
    required String source,
    required String hwdec,
    int? deadlineMs,
  }) {
    _cancelFirstFrameWatchdog();
    _watchdogSession = session;
    _watchdogIndex = index;
    _watchdogSource = source;
    _watchdogHwdec = hwdec;
    _watchdogKey = index >= 0 && index < _queue.length
        ? _queue[index].key
        : '';
    final now = DateTime.now().millisecondsSinceEpoch;
    _watchdogStartedAtMs = now;
    _watchdogOpenBusyRetries = 0;
    var delayMs = _firstFrameWatchdogMs;
    if (deadlineMs != null) {
      final remaining = deadlineMs - now;
      if (remaining > delayMs) delayMs = remaining;
      if (delayMs > _maxBiliFirstFrameBudgetMs) {
        delayMs = _maxBiliFirstFrameBudgetMs;
      }
    }
    _firstFrameWatchdog = Timer(
      Duration(milliseconds: delayMs),
      () => _onFirstFrameWatchdog(session),
    );
    _armHwdecProbe(hwdec);
  }

  /// 6S 等低内存机型的低吞吐看门狗：起播后 8 秒检查一次真实推进比。
  ///
  /// 只看一个窗口；`ShortVideoPerf.lowMemory` 在触发时才读，避免首次
  /// open 早于内存探测完成时漏看。非 6S 机型直接返回，不改变现有行为。
  void _armThroughputWatchdog({
    required int session,
    required int index,
    required String source,
    required String hwdec,
  }) {
    _cancelThroughputWatchdog();
    _throughputIndex = index;
    _throughputSource = source;
    _throughputKey = index >= 0 && index < _queue.length
        ? _queue[index].key
        : '';
    _throughputHwdec = hwdec;
    _throughputStartAtMs = DateTime.now().millisecondsSinceEpoch;
    _throughputStartPositionMs = _player.positionInMilliseconds;
    _throughputWatchdog = Timer(
      const Duration(milliseconds: _throughputWindowMs),
      () => _onThroughputWatchdog(session),
    );
  }

  void _cancelThroughputWatchdog() {
    _throughputWatchdog?.cancel();
    _throughputWatchdog = null;
    _throughputIndex = -1;
    _throughputKey = '';
    _throughputSource = 'auto';
    _throughputStartAtMs = 0;
    _throughputStartPositionMs = 0;
  }

  void _onThroughputWatchdog(int session) {
    _throughputWatchdog = null;
    if (_disposed || _leaving || session != _openSession) return;
    if (!ShortVideoPerf.lowMemory) return;
    if (_opening || _recovering || _pendingOpenIndex != null) return;
    if (_throughputIndex < 0 || _throughputIndex >= _queue.length) return;
    if (_throughputIndex != _index) return;
    if (_player.dataStatus.value != DataStatus.loaded) return;
    if (_appPaused ||
        IOSPipHelper.isActive ||
        !_firstFrameSeen ||
        !_player.playerStatus.isPlaying ||
        _player.isBuffering.value) {
      DiagProbe.event('throughput-skip', <String, Object?>{
        'reason': _appPaused
            ? 'app-paused'
            : (IOSPipHelper.isActive
                  ? 'pip'
                  : (!_firstFrameSeen
                        ? 'no-first-frame'
                        : (_player.isBuffering.value
                              ? 'buffering'
                              : 'not-playing'))),
        'index': _throughputIndex,
        'key': _throughputKey,
        'hwdecRequested': _throughputHwdec,
        'positionMs': _player.positionInMilliseconds,
      });
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsedMs = now - _throughputStartAtMs;
    if (elapsedMs <= 0) return;
    final advanceMs =
        _player.positionInMilliseconds - _throughputStartPositionMs;
    final ratio = advanceMs / elapsedMs;
    final sample = DiagProbe.playbackSample(
      'throughput-check',
      functional: true,
      extra: <String, Object?>{
        'source': _throughputSource,
        'index': _throughputIndex,
        'key': _throughputKey,
        'windowMs': elapsedMs,
        'positionAdvanceMs': advanceMs,
        'positionRatio': ratio,
        'hwdecRequested': _throughputHwdec,
        'buffering': _player.isBuffering.value,
        'mediaBytes': _currentMediaBytes,
        'mediaBitrateKbps': _currentMediaBitrateKbps,
      },
    );
    final estFps = _numOf(sample['estimatedVfFps']);
    final sourceFps = _numOf(sample['containerFps']);
    final fpsLow =
        estFps != null &&
        (estFps <= 0 ||
            (sourceFps != null && sourceFps > 0
                ? estFps < sourceFps * _throughputFpsFloorRatio
                : estFps < _throughputFpsFloorWithoutSource));
    final low = (advanceMs >= 0 && ratio < _throughputRatioFloor) || fpsLow;
    if (!low) {
      DiagProbe.event('throughput-ok', <String, Object?>{
        'index': _throughputIndex,
        'key': _throughputKey,
        'positionRatio': ratio,
        'estimatedVfFps': estFps,
        'sourceFps': sourceFps,
      });
      return;
    }
    final extra = <String, Object?>{
      'positionRatio': ratio,
      'estimatedVfFps': estFps,
      'sourceFps': sourceFps,
      'windowMs': elapsedMs,
      'positionAdvanceMs': advanceMs,
      'hwdecCurrent': sample['hwdec'],
      'videoParamsW': sample['videoParamsW'],
      'videoParamsH': sample['videoParamsH'],
      'demuxerCacheTime': sample['demuxerCacheTime'],
      'mediaBytes': _currentMediaBytes,
      'mediaBitrateKbps': _currentMediaBitrateKbps,
    };
    if (_throughputHwdec != _hwdecFallback &&
        _fallbackToAutoCopy(
          reason: 'low-throughput',
          index: _throughputIndex,
          source: _throughputSource,
          elapsedMs: elapsedMs,
          elapsedFrom: 'throughput-window',
          eventName: 'hwdec-throughput-fallback',
          openSource: 'hwdec-throughput-fallback',
          extra: extra,
        )) {
      return;
    }
    // 已经回滚过 auto-copy 仍然低，或当前无法独占重开：对 B 站/高码率
    // 条目给一次可见提示。接口只返回一条地址，没有可切换的清晰度档位。
    _notifyThroughputDegraded(extra);
  }

  void _notifyThroughputDegraded(Map<String, Object?> extra) {
    final index = _throughputIndex;
    if (index < 0 || index >= _queue.length) return;
    final entry = _queue[index];
    final key = entry.key;
    final bitrate = _currentMediaBitrateKbps ?? 0;
    final highBitrate = bitrate >= _throughputHighBitrateKbps;
    final actionable = entry.isBili || highBitrate;
    DiagProbe.event('throughput-degraded', <String, Object?>{
      ...extra,
      'index': index,
      'key': key,
      'source': _throughputSource,
      'hwdecRequested': _throughputHwdec,
      'isBili': entry.isBili,
      'highBitrate': highBitrate,
      'action': actionable ? 'prompt' : 'none',
    });
    if (!actionable) return;
    if (!mounted || _disposed || _leaving) return;
    if (!_throughputDegradedKeys.add(key)) return;
    SmartDialog.showToast('当前设备解码吞吐不足，建议跳过该视频或换低清晰度');
  }

  void _cancelFirstFrameWatchdog() {
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    _watchdogGraceUsed = false;
    _watchdogOpenBusyRetries = 0;
    _cancelHwdecProbe();
  }

  void _onFirstFrameWatchdog(int session) {
    _firstFrameWatchdog = null;
    if (_disposed || _leaving || session != _openSession) return;
    if (_firstFrameSeen) {
      _recoverStreak = 0;
      _skipStreak = 0;
      return;
    }
    if (_hasFirstFrameNow()) {
      _firstFrameSeen = true;
      _recoverStreak = 0;
      _skipStreak = 0;
      DiagProbe.event('first-frame-seen', <String, Object?>{
        'index': _watchdogIndex,
        'source': _watchdogSource,
        'via': 'watchdog',
        'positionMs': _player.positionInMilliseconds,
        'videoWidth': _mpvVideoWidth(),
        'textureWidth': _player.videoPlayerController?.state.width,
        'textureId': _player.videoController?.id.value,
      });
      return;
    }
    final sinceOpenMs =
        DateTime.now().millisecondsSinceEpoch - _watchdogStartedAtMs;
    // 这次 open 还卡在 resolve/setDataSource/play 里没回来：先别拆播放器，
    // 一秒后再看。否则可能在别人 await 的中途把实例 dispose 掉；也不能在
    // 这一步按「已暂停」放过——open 还没收尾时 playing 本来就可能为 false。
    if (_opening) {
      _watchdogOpenBusyRetries++;
      if (_watchdogOpenBusyRetries > _maxWatchdogOpenBusyRetries) {
        DiagProbe.event('first-frame-watchdog-open-stuck', <String, Object?>{
          'index': _watchdogIndex,
          'source': _watchdogSource,
          'retries': _watchdogOpenBusyRetries,
          'sinceOpenMs': sinceOpenMs,
          'isBuffering': _player.isBuffering.value,
          'positionMs': _player.positionInMilliseconds,
        });
        return;
      }
      _firstFrameWatchdog = Timer(
        const Duration(seconds: 1),
        () => _onFirstFrameWatchdog(session),
      );
      return;
    }
    // 用户主动暂停在首帧之前不是黑屏，不能把播放器拆掉重建；恢复播放时
    // 由 _togglePlay 重新挂看门狗。
    if (!_player.playerStatus.isPlaying && !_player.isBuffering.value) {
      DiagProbe.event('first-frame-watchdog-paused', <String, Object?>{
        'index': _watchdogIndex,
        'source': _watchdogSource,
        'positionMs': _player.positionInMilliseconds,
        'videoWidth': _player.videoPlayerController?.state.width,
      });
      return;
    }
    // 只在真正后台（appPaused=true 且非 PiP 活跃）才跳过重建。前台即便
    // 正在 PiP（pipActive=true）也要完整重建——build58 诊断显示此前
    // pipActive=true 且 appPaused=false 时也被这里跳过，导致黑屏只有声音
    // 不自愈。真正后台的 PiP 保活由 C23 原生侧处理，这里不碰；回前台补
    // 判定由 didChangeAppLifecycleState 的 resumed 分支负责。
    if (_appPaused && !IOSPipHelper.isActive) {
      DiagProbe.event('auto-recover-skipped', <String, Object?>{
        'index': _watchdogIndex,
        'source': _watchdogSource,
        'reason': 'app-paused-or-pip',
        'sinceOpenMs': sinceOpenMs,
        'pipActive': IOSPipHelper.isActive,
        'appPaused': _appPaused,
      });
      return;
    }
    // 网络慢导致的 buffering 不是黑屏；给一次 1.5 秒宽限，避免刚起播就
    // 把正常加载中的播放器整实例拆掉。
    if (_player.isBuffering.value && !_watchdogGraceUsed) {
      _watchdogGraceUsed = true;
      DiagProbe.event('first-frame-watchdog-grace', <String, Object?>{
        'index': _watchdogIndex,
        'source': _watchdogSource,
        'sinceOpenMs': sinceOpenMs,
      });
      _firstFrameWatchdog = Timer(
        const Duration(milliseconds: 1500),
        () => _onFirstFrameWatchdog(session),
      );
      return;
    }
    final width = _player.videoPlayerController?.state.width ?? 0;
    // 直通硬解首帧超时：先回滚 auto-copy 重开同一条一次，仍不行才走原来
    // 的整实例自愈。回滚按条目 key 只做一次，不会在两种模式间循环。
    final canHwdecFallback =
        _watchdogHwdec != _hwdecFallback && _watchdogKey.isNotEmpty;
    DiagProbe.event('first-frame-watchdog-timeout', <String, Object?>{
      'index': _watchdogIndex,
      'source': _watchdogSource,
      'sinceOpenMs': sinceOpenMs,
      'positionMs': _player.positionInMilliseconds,
      'videoWidth': _mpvVideoWidth(),
      'textureWidth': width,
      'openBusyRetries': _watchdogOpenBusyRetries,
      'isBuffering': _player.isBuffering.value,
      'dataStatus': _player.dataStatus.value.name,
      'textureId': _player.videoController?.id.value,
      'hwdec': _readHwdecCurrent(),
      'hwdecRequested': _watchdogHwdec,
      'hwdecFallback': canHwdecFallback,
    });
    // B 站条目先走一次「重取 playurl」兜底：首帧拿不到经常是签名地址过期/
    // 换 CDN，重开同一条比整实例重建更对症。按 key 只重试一次；重开后的
    // 看门狗再超时就直接跳下一条，不在这里做第二次重试。
    final watchdogIndex = _watchdogIndex;
    final biliEntry = watchdogIndex >= 0 && watchdogIndex < _queue.length
        ? _queue[watchdogIndex]
        : null;
    if (biliEntry != null && biliEntry.isBili) {
      final key = biliEntry.key;
      _cancelFirstFrameWatchdog();
      _completionArmed = false;
      if (_biliPlayurlRetried.add(key)) {
        DiagProbe.event('bili-firstframe-retry', <String, Object?>{
          'index': watchdogIndex,
          'attempt': 1,
          'sinceOpenMs': sinceOpenMs,
          'key': key,
          'source': _watchdogSource,
          'hwdec': _watchdogHwdec,
          'positionMs': _player.positionInMilliseconds,
          'videoWidth': _mpvVideoWidth(),
          'textureId': _player.videoController?.id.value,
          'budgetMs': _biliFirstFrameBudgetMs,
        });
        unawaited(
          _retryBiliWithFreshPlayurl(watchdogIndex, sinceOpenMs),
        );
        return;
      }
      unawaited(_skipToNext('bili-firstframe-retry-failed'));
      return;
    }
    if (canHwdecFallback &&
        _fallbackToAutoCopy(
          reason: 'no-first-frame',
          index: _watchdogIndex,
          source: _watchdogSource,
          elapsedMs: sinceOpenMs,
          elapsedFrom: 'watchdog-open',
        )) {
      return;
    }
    unawaited(
      _recoverNoFirstFrame(
        sinceOpenMs: sinceOpenMs,
        source: _watchdogSource,
      ),
    );
  }

  /// 把当前这一条用 auto-copy 重开一次；返回 true 表示已经发起回滚 open。
  ///
  /// 这是唯一一次回滚：[_hwdecFallbackKeys] 记下条目 key 之后，后续任何
  /// open（含首帧自愈重建）都直接沿用 auto-copy，不会再来回切换。
  bool _fallbackToAutoCopy({
    required String reason,
    required int index,
    required String source,
    required int elapsedMs,
    required String elapsedFrom,
    String eventName = 'hwdec-fallback',
    String? openSource,
    Map<String, Object?> extra = const {},
  }) {
    if (_disposed || _leaving || _opening || _recovering) return false;
    if (_pendingOpenIndex != null) return false;
    if (IOSPipHelper.isActive) return false;
    // 单例被 B站/PiP 持有时 _open 会在 pre-release 阶段中止；先判掉，
    // 免得留下一条「并未真正发生」的回滚日志、还把该条永久降级。
    if (!_player.canReleaseSolo) return false;
    if (index < 0 || index >= _queue.length || index != _index) return false;
    final key = _queue[index].key;
    if (key.isEmpty) return false;
    final from = _effectiveHwdecFor(key);
    if (from == _hwdecFallback) return false;
    if (_hwdecFallbackKeys.length >= _maxHwdecFallbackKeys) {
      _hwdecFallbackKeys.remove(_hwdecFallbackKeys.first);
    }
    _hwdecFallbackKeys.add(key);
    _cancelFirstFrameWatchdog();
    // 同一条要整实例重开，连播计数从 0 重新算。
    _autoPlaysSinceRebuild = 0;
    DiagProbe.event(eventName, <String, Object?>{
      ...extra,
      'reason': reason,
      'from': from,
      'to': _hwdecFallback,
      'elapsedMs': elapsedMs,
      'elapsedFrom': elapsedFrom,
      'index': index,
      'key': key,
      'source': source,
      'hwdecCurrent': _readHwdecCurrent(),
      'firstFrameSeen': _firstFrameSeen,
      'positionMs': _player.positionInMilliseconds,
      'textureId': _player.videoController?.id.value,
    });
    unawaited(
      _open(index, source: openSource ?? 'hwdec-fallback', force: true),
    );
    return true;
  }

  /// B 站首帧超时的第一层兜底：清掉预热缓存，重新解析 playurl 后重开一次。
  ///
  /// 原始 open 已经等过一轮 2800ms，这里不再给完整预算：把「原始 open 起点
  /// + [_biliFirstFrameBudgetMs]」作为截止时刻传给重开的看门狗，6S 这类
  /// 老机型总窗口约 12s，其它机型约 8s。重开还失败就跳下一条。
  Future<void> _retryBiliWithFreshPlayurl(int index, int sinceOpenMs) async {
    if (_disposed || _leaving || _opening || _recovering) return;
    if (_pendingOpenIndex != null) return;
    if (index != _index || index < 0 || index >= _queue.length) return;
    if (!_queue[index].isBili) return;
    final deadlineMs =
        DateTime.now().millisecondsSinceEpoch -
        sinceOpenMs +
        _biliFirstFrameBudgetMs;
    _biliRetryOpenSucceeded = false;
    // 重开前先停音频；_open 会在 setDataSource 前释放旧 texture，
    // 避免「画面已经黑了、声音还在播」。
    try {
      await _player.pause(notify: false);
    } catch (_) {}
    if (!mounted || _disposed || _leaving) return;
    // 停音频的 await 期间用户可能已经点了别的条目/触发了自愈；此时让路，
    // 不能用 force 把用户的选择顶掉。
    if (_opening || _recovering || _pendingOpenIndex != null) return;
    await _open(
      index,
      source: 'bili-retry',
      force: true,
      uncachedResolve: true,
      firstFrameDeadlineMs: deadlineMs,
    );
    if (!mounted || _disposed || _leaving) return;
    // 用户在这期间点了别的条目，优先听用户的，不要把它跳掉。
    // `_opening` 为 true 说明 finally 补跳的 pending open 已经接手。
    if (_opening || _recovering || _pendingOpenIndex != null) return;
    if (_index != index) return;
    if (!_biliRetryOpenSucceeded) {
      await _skipToNext('bili-retry-open-failed');
    }
  }

  /// 统一的「这条救不回来，跳下一条」出口。
  ///
  /// 与 [_advance] 共用 [_nextIndex]：随机模式沿用牌堆/已播去重，顺序与
  /// 循环模式照旧。切之前先停音频，再交给 [_open] 释放旧 texture，
  /// 不会出现「画面切黑、声音还在播」。
  Future<bool> _skipToNext(String reason) async {
    if (_disposed || _leaving || _queue.isEmpty) return false;
    if (_shuffle) await _shuffleRestore;
    if (!mounted || _disposed || _leaving) return false;
    // 等待牌堆恢复期间用户可能已经发起了新的 open；此时让用户的选择优先，
    // 不要再排一个 skip 把 pending 覆盖掉。
    if (_opening || _recovering || _pendingOpenIndex != null) return false;
    if (_skipStreak + 1 >= _maxConsecutiveSkip) {
      _skipStreak = _maxConsecutiveSkip;
      _haltAfterSkipLimit(reason);
      return false;
    }
    final fromIndex = _index;
    final mode = _shuffle ? 'shuffle' : _repeat.name;
    final next = _nextIndex(auto: true);
    final attempt = _skipStreak + 1;
    if (next == null || next == _index) {
      DiagProbe.event('item-skip', <String, Object?>{
        'reason': reason,
        'fromIndex': fromIndex,
        'toIndex': null,
        'mode': mode,
        'attempt': attempt,
        'result': _queue.length <= 1 ? 'single-item' : 'no-next',
      });
      if (mounted) {
        setState(
          () => _error = _queue.length <= 1
              ? '没有可播放的下一条'
              : '当前播放模式下没有下一条',
        );
      }
      return false;
    }
    _skipStreak++;
    _cancelFirstFrameWatchdog();
    _completionArmed = false;
    DiagProbe.event('item-skip', <String, Object?>{
      'reason': reason,
      'fromIndex': fromIndex,
      'toIndex': next,
      'mode': mode,
      'attempt': attempt,
      'key': _queue[fromIndex].key,
      'nextKey': _queue[next].key,
    });
    try {
      await _player.pause(notify: false);
    } catch (_) {}
    if (!mounted || _disposed || _leaving) return false;
    if (_opening || _recovering || _pendingOpenIndex != null) return false;
    await _open(next, source: 'skip');
    if (!mounted || _disposed || _leaving) return false;
    if (_index != next || _opening || _recovering || _pendingOpenIndex != null) {
      return true;
    }
    // 跳过后的这条连地址都没解析出来：接着跳，计数与停在 3 条的约束
    // 由 [_skipToNext] 自身保证。
    if (_openMediaMissing && _error != null) {
      return _skipToNext('skip-resolve-failed');
    }
    return true;
  }

  /// 连续 [_maxConsecutiveSkip] 条都失败：停下、停音频并给可见提示。
  void _haltAfterSkipLimit(String reason) {
    _cancelFirstFrameWatchdog();
    _completionArmed = false;
    final mode = _shuffle ? 'shuffle' : _repeat.name;
    DiagProbe.event('item-skip', <String, Object?>{
      'reason': reason,
      'fromIndex': _index,
      'toIndex': null,
      'mode': mode,
      'attempt': _skipStreak,
      'result': 'stop-after-$_maxConsecutiveSkip',
    });
    DiagProbe.event('item-skip-stop', <String, Object?>{
      'reason': reason,
      'index': _index,
      'streak': _skipStreak,
      'mode': mode,
    });
    unawaited(() async {
      try {
        await _player.pause(notify: false);
      } catch (_) {}
    }());
    if (!mounted) return;
    final message = '连续 $_maxConsecutiveSkip 条视频播放失败，已停止自动跳过';
    setState(() => _error = message);
    SmartDialog.showToast(message);
  }

  /// 整实例重建：dispose 当前 player/texture，重新 getInstance 并挂监听，
  /// 再以 [openSource] 重开 [index]。返回 true 表示重建（含重开）已执行。
  ///
  /// 调用方负责：置 [_recovering] / 取消看门狗 / 写 'auto-recover' 起点日志；
  /// 这里只做"拆 + 重建 + 重开"的机械动作，供首帧自愈和定期主动重建共用。
  Future<bool> _rebuildPlayerInstance({
    required int index,
    required String reason,
    required String openSource,
    required int retry,
  }) async {
    final sw = Stopwatch()..start();
    int? releasedTextureId;
    try {
      // 与切条同一原则：共享单例不能拆，否则会把 B站/PiP 的画面一起换掉。
      // 自愈失败时留证交给看门狗放弃，不再继续拆。
      if (!_player.canReleaseSolo) {
        DiagProbe.event('auto-recover-skipped', <String, Object?>{
          'index': index,
          'reason': 'shared-player',
          'source': openSource,
        });
        return false;
      }
      _detachPlayerListeners();
      _lastPositionTickMs = 0;
      // 必须等 native texture 真正释放：旧代码只调同步 dispose() 就立刻
      // getInstance，旧 FlutterTexture 还在拆、新解码器已经建起来，等于
      // 又踩回「同一 MPV 上下文/旧纹理未清」的坑。releaseTexture 内部
      // await Player.dispose()，返回时 VideoOutputManager 已收尾。
      //
      // dispose 失败时不能继续：getInstance 会拿回同一个实例，等于在旧
      // 纹理上重开新流。这里透传失败、恢复监听并交给看门狗放弃。
      try {
        releasedTextureId = await _player.releaseTexture(reason: 'recover');
      } catch (error) {
        DiagProbe.event('auto-recover-failed', <String, Object?>{
          'index': index,
          'reason': reason,
          'phase': 'release-texture',
          'error': '$error',
          'retry': retry,
        });
        _attachPlayerListeners();
        return false;
      }
      if (!mounted || _disposed || _leaving) return false;
      final instanceCleared = PlPlayerController.instance == null;
      _player = PlPlayerController.getInstance();
      _player.textureSource = 'douyin';
      _attachPlayerListeners();
      _progress.value = const _PlaybackProgress();
      sw.stop();
      DiagProbe.event('auto-recover-rebuilt', <String, Object?>{
        'index': index,
        'reason': reason,
        'disposeMs': sw.elapsedMilliseconds,
        'releasedTextureId': releasedTextureId,
        'instanceCleared': instanceCleared,
        'textureId': _player.videoController?.id.value,
        'retry': retry,
      });
      // 任何一次整实例重建都把连播计数归零，下一轮从 1 开始计。
      _autoPlaysSinceRebuild = 0;
      await _open(index, source: openSource, force: true);
      return true;
    } catch (error) {
      DiagProbe.event('auto-recover-failed', <String, Object?>{
        'index': index,
        'reason': reason,
        'error': '$error',
      });
      return false;
    } finally {
      _recovering = false;
      _consumePendingOpen();
    }
  }

  /// 首帧超时的自愈：整实例重建，等价于用户去播放列表里手动选这一条。
  ///
  /// 连播约 30 条后旧 player/texture 会进入「有声音没画面」的状态，单靠
  /// 再 open 一次救不回来；必须 dispose 当前单例（连同 FlutterTexture），
  /// 重新 getInstance 并 setDataSource，才能新建解码器和纹理。
  Future<void> _recoverNoFirstFrame({
    required int sinceOpenMs,
    required String source,
  }) async {
    if (_recovering) return;
    if (_disposed || _leaving || _opening) return;
    // 同看门狗守卫：只在真正后台（非 PiP 活跃）才跳过；前台 PiP 也要重建。
    if (_appPaused && !IOSPipHelper.isActive) {
      DiagProbe.event('auto-recover-skipped', <String, Object?>{
        'index': _index,
        'reason': 'app-paused-or-pip',
        'source': source,
      });
      return;
    }
    // 同一条连续重建仍拿不到首帧，说明不是 texture 卡死而是片源/解码器
    // 本身有问题；再拆下去只会反复黑屏，放弃并留证据。
    if (_recoverStreak >= 3) {
      DiagProbe.event('auto-recover-gave-up', <String, Object?>{
        'index': _index,
        'source': source,
        'streak': _recoverStreak,
      });
      return;
    }
    _recovering = true;
    _recoverStreak++;
    _completionArmed = false;
    _cancelFirstFrameWatchdog();
    final index = _index;
    final attempt = ++_autoRecoverCount;
    DiagProbe.event('auto-recover', <String, Object?>{
      'index': index,
      'reason': 'no-first-frame',
      'source': source,
      'sinceOpenMs': sinceOpenMs,
      'positionMs': _player.positionInMilliseconds,
      'textureId': _player.videoController?.id.value,
      'retry': attempt,
    });
    await _rebuildPlayerInstance(
      index: index,
      reason: 'no-first-frame',
      openSource: 'auto-recover',
      retry: attempt,
    );
  }

  /// 自动连播复用同一 texture，每 [_autoRebuildInterval] 条主动整实例重建一次，
  /// 避免 texture/解码器长期复用累积劣化（手动选播 = 完整重建能恢复，说明重建有效）。
  /// 在 [_next] 准备自动下一条前调用；返回 true 表示已重建并重开，调用方不要再 open。
  Future<bool> _maybeAutoRebuildBeforeNext(int nextIndex) async {
    if (_autoPlaysSinceRebuild < _autoRebuildInterval) return false;
    if (_recovering || _disposed || _leaving || _opening) return false;
    // 真正后台（非 PiP 活跃）不主动拆播放器，交给 C23 原生 PiP 保活。
    if (_appPaused && !IOSPipHelper.isActive) return false;
    _recovering = true;
    _completionArmed = false;
    _cancelFirstFrameWatchdog();
    final attempt = ++_autoRecoverCount;
    DiagProbe.event('auto-recover', <String, Object?>{
      'index': nextIndex,
      'reason': 'proactive-rebuild',
      'source': 'auto',
      'sinceRebuild': _autoPlaysSinceRebuild,
      'textureId': _player.videoController?.id.value,
      'retry': attempt,
    });
    final rebuilt = await _rebuildPlayerInstance(
      index: nextIndex,
      reason: 'proactive-rebuild',
      openSource: 'auto',
      retry: attempt,
    );
    return rebuilt;
  }

  void _notePlayed(String key) {
    _played.add(key);
    if (_deckSignature.isNotEmpty) {
      unawaited(
        ShortVideoShuffleStore.save(
          signature: _deckSignature,
          played: _played,
        ),
      );
    }
  }

  /// 解析某一条的播放地址。命中预热结果时直接复用，自动连播不再从零开始
  /// 取 cookie + 解析。
  Future<QueueMedia?> _resolveMedia(
    QueueEntry entry, {
    bool uncached = false,
  }) async {
    if (uncached) {
      // 首帧失败重取时，预热里那条地址可能已经过期，必须清掉再走完整
      // 解析（B 站会重新请求一次 playurl），不能命中旧的 prefetch。
      _prefetchKey = null;
      _prefetchFuture = null;
      return _resolveMediaUncached(entry);
    }
    if (_prefetchKey == entry.key) {
      final future = _prefetchFuture;
      _prefetchKey = null;
      _prefetchFuture = null;
      if (future != null) {
        try {
          final media = await future;
          if (media != null && media.url.isNotEmpty) {
            DiagProbe.event('prefetch-hit', <String, Object?>{
              'key': entry.key,
            });
            return media;
          }
        } catch (_) {}
      }
    }
    return _resolveMediaUncached(entry);
  }

  /// 真正走磁盘缓存 / cookie / 网络解析的路径。
  Future<QueueMedia?> _resolveMediaUncached(QueueEntry entry) async {
    final direct = await fastOfflineMedia(entry);
    if (direct != null) return direct;
    final video = entry.short;
    final cookie = video == null
        ? ''
        : await ShortVideoWeb.cookieHeader(
            (ShortVideoPlatform.fromId(video.platform) ??
                    ShortVideoPlatform.douyin)
                .cookieDomainNeedle,
          );
    if (!mounted) return null;
    return resolveQueueEntry(entry, cookie: cookie);
  }

  /// 算下一条要预热谁的 key，与播完自动下一项走同一套 [_nextIndex]。
  String _prefetchTargetKey() {
    if (_queue.length <= 1) return '';
    // 历史读完之前不提前发牌：提前发牌会把上次播过的条目又放进来。
    // 读完（或队列换过、旧历史作废）后牌堆空了就补一轮，保证一轮末尾
    // 仍能预取出下一条。
    if (_shuffle && _deck.isEmpty && _shuffleRestored) _refillDeck();
    final index = _nextIndex(auto: true, consumeDeck: false);
    if (index == null || index == _index) return '';
    return _queue[index].key;
  }

  /// 本条已经起播后，提前解析下一条的地址。切条时 [_resolveMedia] 命中，
  /// 首帧不再等一次完整的 cookie + 解析往返。
  void _prefetchNext() {
    if (_disposed || _leaving) return;
    final key = _prefetchTargetKey();
    if (key.isEmpty || key == _prefetchKey) return;
    final index = _queue.indexWhere((e) => e.key == key);
    if (index < 0) return;
    final entry = _queue[index];
    _prefetchKey = key;
    _prefetchFuture = _resolveMediaUncached(entry).catchError((_) => null);
    DiagProbe.event('prefetch-start', <String, Object?>{'key': key});
  }

  /// 复用 B 站播放页的完成监听：controller 把 mpv 的 completed 流转成
  /// [PlayerStatus.completed] 后回调到这里。
  ///
  /// 只有「上一条已经真正播起来」才允许自动下一条；主动切歌、解析失败、
  /// 退出页面都不算完成。上膛只发生在当前会话成功加载并起播之后，
  /// 迟到的 `playing` 不会再打开标记。
  void _onPlayerStatus(PlayerStatus status) {
    final isPlaying = _player.playerStatus.isPlaying;
    if (_isPlaying.value != isPlaying) {
      _isPlaying.value = isPlaying;
    }
    if (status == PlayerStatus.playing) {
      _armPipAutoEnter('status-playing');
    } else {
      _disarmPipAutoEnter('status-${status.name}');
    }
    _pushProgress(force: true);
    _publishPipState();
    _publishBackgroundState(status: status);
    _syncAndroidPipActions();
    if (status == PlayerStatus.completed) {
      if (!_completionArmed || _armedSession != _openSession) return;
      if (_player.dataStatus.value != DataStatus.loaded) return;
      _completionArmed = false;
      if (_opening || _leaving || _disposed || !mounted) return;
      unawaited(_handleCompleted());
    }
  }

  /// 播完这一条后按当前模式决定下一步。
  ///
  /// 随机优先：开了随机就继续从牌堆取，牌堆空了 [_refillDeck] 会重开一轮，
  /// 所以播完仍然是列表循环的语义。五种固定模式的对应关系：
  /// 播完暂停 = 停在末尾；单个循环 = 重播本条；顺序播放 = 到末尾停；
  /// 列表循环 / 自动连播 = 到末尾回到第一条（收藏列表没有相关视频，
  /// 自动连播与列表循环等价）。
  Future<void> _handleCompleted() async {
    DiagProbe.event('repeat-completed', <String, Object?>{
      'mode': _shuffle ? 'shuffle' : _repeat.name,
      'index': _index,
      'queueLength': _queue.length,
    });
    if (_shuffle) {
      await _advance(auto: true);
      return;
    }
    switch (_repeat) {
      case PlayRepeat.pause:
        return;
      case PlayRepeat.singleCycle:
        try {
          await _player.play(repeat: true);
          if (!mounted || _disposed || _leaving) return;
          _completionArmed = true;
          _armedSession = _openSession;
          _isPlaying.value = _player.playerStatus.isPlaying;
          _pushProgress(force: true);
          _publishPipState();
        } catch (error) {
          if (mounted) setState(() => _error = '重播失败：$error');
        }
        return;
      case PlayRepeat.listOrder:
      case PlayRepeat.listCycle:
      case PlayRepeat.autoPlayRelated:
        await _advance(auto: true);
        return;
    }
  }

  Future<void> _restoreShuffle() async {
    final keys = _queue.map((e) => e.key).toList(growable: false);
    final signature = ShortVideoShuffleStore.signatureOf(keys);
    _deckSignature = signature;
    final saved = await ShortVideoShuffleStore.load();
    if (!mounted) return;
    // 读取历史期间队列可能被整份替换（从播放列表点播），旧签名作废。
    if (_deckSignature != signature) return;
    _shuffleRestored = true;
    if (saved != null && saved.signature == signature) {
      _played.addAll(saved.played.where(keys.contains));
      // 用户在历史读完前就切到随机并发了牌：把历史里已播过的从牌堆剔除，
      // 否则这一轮可能马上又抽到刚播过的条目。
      _deck.removeWhere(_played.contains);
    }
    // 历史读回来之前牌堆是空的，首条播完后拿不到预取目标。恢复完就按
    // 同一套牌堆发一次牌，并提前解析下一条；仍然只保留 1 条预取。
    if (_shuffle && _deck.isEmpty && _queue.length > 1) {
      _refillDeck();
      _prefetchNext();
    }
  }

  /// 统一选下一项。自动播完与手动「下一条」共用这一套模式判定，只有
  /// 两处语义差别：播完暂停在末尾停、单曲循环在播完时重播；手动切条
  /// 始终往后走一项。随机从牌堆取，且绝不把当前这条再发回来。
  ///
  /// [consumeDeck] 为 false 时只预览随机目标，不把牌堆项取走（预取用）。
  int? _nextIndex({required bool auto, bool consumeDeck = true}) {
    final length = _queue.length;
    if (length <= 1) return null;
    if (_shuffle) {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (_deck.isEmpty) _refillDeck();
        for (var i = 0; i < _deck.length; i++) {
          final key = _deck[i];
          final index = _queue.indexWhere((e) => e.key == key);
          if (index < 0 ||
              index == _index ||
              _played.contains(key)) {
            // 队列被整份换过（旧牌失效）、已经播过或就是当前这条：
            // 都从牌堆里清掉，保证一轮之内不重复。
            _deck.removeAt(i);
            i--;
            continue;
          }
          if (consumeDeck) _deck.removeAt(i);
          return index;
        }
        // 牌堆里只剩当前项 / 已播项：发下一轮再从新牌堆里挑。
        // 预取同样走这一步，播完时直接命中下一轮的首项。
        if (attempt == 0) continue;
        break;
      }
      // 极端情况下整条队列都被标成已播：退回到紧跟其后的一条，
      // 至少不会原地重播当前视频。
      return (_index + 1) % length;
    }
    return switch (_repeat) {
      PlayRepeat.pause =>
        auto ? null : (_index + 1 < length ? _index + 1 : null),
      PlayRepeat.listOrder => _index + 1 < length ? _index + 1 : null,
      PlayRepeat.singleCycle => auto ? _index : (_index + 1) % length,
      PlayRepeat.listCycle => (_index + 1) % length,
      PlayRepeat.autoPlayRelated => (_index + 1) % length,
    };
  }

  /// 取下一项并开流。播完自动走 [auto] = true，手动切条走 false。
  Future<void> _advance({required bool auto, String source = 'auto'}) async {
    if (_shuffle) await _shuffleRestore;
    final next = _nextIndex(auto: auto);
    if (next == null || next == _index) {
      _diagSwitchRequest(source, _index);
      _diagSwitchBlocked(
        source,
        _queue.length <= 1
            ? 'single-item'
            : _shuffle
            ? 'shuffle-exhausted'
            : 'end-of-queue',
        targetIndex: _index,
      );
      return;
    }
    _diagSwitchRequest(source, next);
    if (auto && await _maybeAutoRebuildBeforeNext(next)) return;
    await _open(next, source: source);
  }

  /// 下一条按钮 / 后台「下一首」：手动语义，即使当前是播完暂停或单曲
  /// 循环也要往后走。
  Future<void> _next({String source = 'auto'}) =>
      _advance(auto: false, source: source);

  /// 重新发牌：这一轮没播过的都进去，洗一遍。
  void _refillDeck() {
    final remaining = _queue
        .map((e) => e.key)
        .where((key) => key != _current.key && !_played.contains(key))
        .toList();
    if (remaining.isEmpty) {
      // 一轮播完了：重开一轮，但把当前这条留在排除集里，
      // 避免新一轮第一首又正好是刚播完的视频。
      _played.clear();
      remaining.addAll(
        _queue.map((e) => e.key).where((key) => key != _current.key),
      );
    }
    remaining.shuffle();
    _deck
      ..clear()
      ..addAll(remaining);
  }

  Future<void> _previous() async {
    if (_queue.length <= 1) {
      _diagSwitchRequest('next', _index);
      _diagSwitchBlocked('next', 'single-item', targetIndex: _index);
      return;
    }
    final target = (_index - 1 + _queue.length) % _queue.length;
    _diagSwitchRequest('previous', target);
    await _open(target, source: 'previous');
  }

  /// 打开播放列表。列表里调序会回调 [_applyPlaylistOrder]，
  /// 点条目会回调 [_playFromPlaylist]，两边保持同一份顺序。
  Future<void> _openPlaylist() async {
    // 不能靠 Get.to 猜 Navigator：播放页可能是被 Get.off 直接换到首页路由
    // 上的，也可能是嵌在收藏页 Tab 的内层 Navigator 里。走当前 context 的
    // Navigator.of 会拿到播放页自己所在的栈，push 上去的页面才一定会盖在
    // 播放页上面，而不是被播放页挡住——那正是「点了播放列表没反应」。
    final navigator = Navigator.of(context, rootNavigator: true);
    await navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ShortVideoPlaylistPage(
          currentKey: _current.key,
          onReorder: _applyPlaylistOrder,
          onPlay: _playFromPlaylist,
        ),
      ),
    );
  }

  /// 播放列表调序后，把当前队列里同样存在的条目按新顺序重排。
  ///
  /// 队列和播放列表未必完全一样（收藏页直接开播时列表可能是空的），
  /// 所以只重排在两边的条目，其余条目留在原位，不改变队列长度。
  void _applyPlaylistOrder(List<PlaylistItem> items) {
    if (items.isEmpty || _queue.isEmpty) return;
    _prefetchKey = null;
    _prefetchFuture = null;
    final incoming = <String, QueueEntry>{
      for (final entry in _queue) entry.key: entry,
    };
    final playlistKeys = items.map((item) => item.key).toSet();
    final positions = <int>[];
    for (var i = 0; i < _queue.length; i++) {
      if (playlistKeys.contains(_queue[i].key)) {
        positions.add(i);
      }
    }
    if (positions.isEmpty) return;
    final ordered = <QueueEntry>[];
    for (final item in items) {
      final entry = incoming[item.key];
      if (entry != null) ordered.add(entry);
    }
    if (ordered.length != positions.length) return;
    final currentKey = _current.key;
    final next = List<QueueEntry>.of(_queue);
    for (var i = 0; i < positions.length; i++) {
      next[positions[i]] = ordered[i];
    }
    setState(() {
      _queue
        ..clear()
        ..addAll(next);
      final at = _queue.indexWhere((e) => e.key == currentKey);
      if (at >= 0) _index = at;
    });
  }

  /// 播放列表里点了一条：整份列表成为新的播放队列，并从这条开始播。
  void _playFromPlaylist(List<QueueEntry> entries, int index) {
    if (entries.isEmpty) return;
    _prefetchKey = null;
    _prefetchFuture = null;
    final target = index.clamp(0, entries.length - 1);
    final key = entries[target].key;
    _diagSwitchRequest('playlist-select', target);
    final wasCurrentKey = _current.key;
    setState(() {
      _queue
        ..clear()
        ..addAll(entries);
      _index = target;
    });
    // 队列换成了播放列表的整份条目：随机牌堆和历史签名跟着换，
    // 否则旧牌的 key 全都不在队列里，随机模式会一直走回退的顺播。
    final signature = ShortVideoShuffleStore.signatureOf(
      entries.map((e) => e.key),
    );
    if (signature != _deckSignature) {
      _played.clear();
      _deck.clear();
      _deckSignature = signature;
      _shuffleRestored = true;
      if (_shuffle) {
        _refillDeck();
        _prefetchNext();
      }
    }
    // 点的就是当前这条：画面正常就只把队列换成列表顺序，不重新加载打断
    // 播放；但如果现在是黑屏/卡在 buffering/错误态，这一点就是用户手动
    // 救场，必须走和下拉列表选其它条一样的完整重建。
    if (key == wasCurrentKey) {
      final healthy =
          _firstFrameSeen && !_player.isBuffering.value && _error == null;
      _diagSwitchBlocked(
        'playlist-select',
        healthy ? 'duplicate-target' : 'duplicate-target-rebuild',
        targetIndex: target,
      );
      if (!healthy && !_opening && !_recovering) {
        // 用户手动点这一条救场：清掉之前的回滚标记，重新从直通 auto 起。
        _hwdecFallbackKeys.remove(key);
        _throughputDegradedKeys.remove(key);
        _recoverStreak = 0;
        unawaited(
          _recoverNoFirstFrame(sinceOpenMs: 0, source: 'playlist-select'),
        );
      }
      return;
    }
    // 用户手动重选这一条，视为重新尝试直通硬解：一次网络抖动导致的
    // 看门狗超时不应把该条永久降级。
    _hwdecFallbackKeys.remove(key);
    _throughputDegradedKeys.remove(key);
    // 正在解析/加载上一条时也不能丢弃这次点击。_open 会把目标排队，并把
    // 在途会话作废；列表页已经关了，用户点了就必须最终切过去。
    unawaited(_open(target, source: 'playlist-select'));
  }

  Future<void> _togglePlay() async {
    if (_player.playerStatus.isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    // 只重建暂停/播放图标那一小块，不再 setState 整页。
    _isPlaying.value = _player.playerStatus.isPlaying;
    // 首帧前暂停会让看门狗主动让路；恢复播放后补挂一次，别让黑屏没人管。
    if (_player.playerStatus.isPlaying &&
        !_firstFrameSeen &&
        _firstFrameWatchdog == null &&
        _watchdogSession >= 0 &&
        _watchdogSession == _openSession) {
      _armFirstFrameWatchdog(
        session: _watchdogSession,
        index: _watchdogIndex,
        source: _watchdogSource,
        hwdec: _watchdogHwdec,
      );
    }
    _pushProgress(force: true);
    _publishPipState();
    _publishBackgroundState();
    _syncAndroidPipActions();
    if (_player.playerStatus.isPlaying) {
      _armPipAutoEnter('toggle-play');
    } else {
      _disarmPipAutoEnter('toggle-pause');
    }
  }

  Future<void> _enterPip() async {
    if (Platform.isAndroid) {
      final allow = PiliAndroidHelper.isPipAvailable;
      DiagProbe.event('android-pip-enter', <String, Object?>{
        'allow': allow,
        'reason': allow ? 'manual' : 'unsupported',
        'isPlaying': _player.playerStatus.isPlaying,
        'positionMs': _player.positionInMilliseconds,
        'textureId': _player.videoController?.id.value,
      });
      if (!allow) {
        SmartDialog.showToast('这台设备不支持画中画');
        return;
      }
      _pipEntered = true;
      // Android 的 PiP 由 controller 分派到 PageUtils/PiliAndroidHelper，
      // 这里与 B 站播放页的手动入口保持一致，直接请求进入小窗。
      _player.enterPip(autoEnter: false);
      return;
    }
    if (!IOSPipHelper.isAvailable) {
      SmartDialog.showToast('这台设备不支持画中画');
      return;
    }
    _pipEntered = true;
    // 手动按钮立即启动画中画并退后台，和 B 站播放页一致；autoEnter 只 arm
    // 不 start，用户点了按钮却留在前台会看起来什么都没发生。
    _player.enterPip(autoEnter: false);
    _syncPipTicker();
    // 原生 isActive 是异步回来的：暂停时手动进小窗没有 armed 兜底，这里
    // 追几拍补同步，等状态真正变成 active 再把 ticker 起来。只在一次手动
    // 请求后跑有限几拍，不是常驻定时器。
    unawaited(_syncPipTickerAfterEnter());
    // 必须先 enter 再 update：PipSession 还不存在时 update 会被原生直接丢掉。
    unawaited(_pushPipLiteMode());
    // 显式带上 position：进入 PiP 必须强制下发一次，不能命中「状态未变」跳过。
    _publishPipState(_player.positionInMilliseconds);
  }

  /// 原生 PiP 进入/退出回调：只切换一次布局，并同步小窗遥控键。
  void _onAndroidPipModeChanged() {
    if (!mounted || _disposed) return;
    final isPip = PiliAndroidHelper.isPipMode;
    if (isPip == _isPipLayout) return;
    if (isPip) {
      _chromeVisibleBeforePip = _chromeVisible;
      _chromeTimer?.cancel();
      _chromeTimer = null;
      setState(() => _isPipLayout = true);
      _syncAndroidPipActions(force: true);
    } else {
      final restoreChrome = _chromeVisibleBeforePip;
      setState(() {
        _isPipLayout = false;
        _chromeVisible = restoreChrome;
      });
      _pipActionSig = null;
      if (restoreChrome) _scheduleChromeHide();
    }
    DiagProbe.event('android-pip-layout', <String, Object?>{
      'pip': isPip,
      'isPlaying': _player.playerStatus.isPlaying,
      'textureId': _player.videoController?.id.value,
    });
  }

  /// 小窗里的播放/暂停/快进键要和真实播放状态一致。
  /// 只在 PiP 中、签名变化或显式 force 时下发，避免重复 JNI。
  void _syncAndroidPipActions({bool force = false}) {
    if (!Platform.isAndroid || !_isPipLayout) return;
    final isLive = _player.isLive;
    final isPlaying = _player.playerStatus.isPlaying;
    final sig = Object.hash(isLive, isPlaying);
    if (!force && sig == _pipActionSig) return;
    _pipActionSig = sig;
    try {
      PiliAndroidHelper.updatePipActions(
        isLive: isLive,
        isPlaying: isPlaying,
      );
      DiagProbe.event('android-pip-actions', <String, Object?>{
        'isLive': isLive,
        'isPlaying': isPlaying,
      });
    } catch (error) {
      DiagProbe.event('android-pip-actions', <String, Object?>{
        'ok': false,
        'error': '$error',
      });
    }
  }

  Future<void> _syncPipTickerAfterEnter() async {
    // 原生小窗激活偶尔超过 1.6s，补够 3.2s；一旦 active 立即结束，仍然是
    // 有界的一次性追踪，不是常驻定时器。
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_disposed || _leaving) return;
      _syncPipTicker();
      _syncFrameConsumer('pip-enter-poll');
      if (IOSPipHelper.isActive) return;
    }
  }

  /// 播放中武装自动画中画：原生置
  /// `canStartPictureInPictureAutomaticallyFromInline = true`，按 Home 退后台即起小窗。
  void _armPipAutoEnter(String reason) {
    if (_disposed || _leaving || !mounted || _appPaused) return;
    if (Platform.isAndroid) {
      if (_pipAutoArmed) return;
      final allow = PiliAndroidHelper.isPipAvailable;
      DiagProbe.event('android-pip-arm', <String, Object?>{
        'allow': allow,
        'reason': reason,
        'isPlaying': _player.playerStatus.isPlaying,
        'positionMs': _player.positionInMilliseconds,
        'textureId': _player.videoController?.id.value,
      });
      if (!allow) return;
      _pipAutoArmed = true;
      _pipStartRequested = false;
      // SDK >= 31 由原生设置 autoEnterEnabled；更老的版本在真正退后台时
      // 再由 _requestPipAutoEnterOnBackground 显式请求进入。
      _player.enterPip(autoEnter: true);
      return;
    }
    if (_pipAutoArmed || !IOSPipHelper.isAvailable) return;
    final textureId = _player.videoController?.id.value;
    if (textureId == null) return;
    _pipAutoArmed = true;
    _pipStartRequested = false;
    _player.enterPip(autoEnter: true);
    _syncPipTicker();
    _syncFrameConsumer('pip-arm');
    // arm 后原生要先拿到当前状态；显式 position 绕过状态签名去重。
    _publishPipState(_player.positionInMilliseconds);
    DiagProbe.event('pip-auto-arm', <String, Object?>{
      'armed': true,
      'reason': reason,
      'textureId': textureId,
      'isPlaying': _player.playerStatus.isPlaying,
      'positionMs': _player.positionInMilliseconds,
      'pipActive': IOSPipHelper.isActive,
    });
  }

  /// 暂停、切条、离开页面时收起 arm，避免残留后在后台误弹小窗。
  void _disarmPipAutoEnter(String reason) {
    if (!_pipAutoArmed) {
      _syncPipTicker();
      return;
    }
    _pipAutoArmed = false;
    _pipStartRequested = false;
    if (Platform.isAndroid) {
      PiliAndroidHelper.disableAutoEnterPip();
      DiagProbe.event('android-pip-arm', <String, Object?>{
        'allow': true,
        'armed': false,
        'reason': reason,
        'isPlaying': _player.playerStatus.isPlaying,
        'positionMs': _player.positionInMilliseconds,
      });
      return;
    }
    IOSPipHelper.disableAutoEnter();
    _syncPipTicker();
    _syncFrameConsumer('pip-disarm');
    DiagProbe.event('pip-auto-arm', <String, Object?>{
      'armed': false,
      'reason': reason,
      'isPlaying': _player.playerStatus.isPlaying,
      'positionMs': _player.positionInMilliseconds,
      'pipActive': IOSPipHelper.isActive,
    });
  }

  void _onPipAutoEnter() {
    if (_disposed) return;
    _pipStartRequested = false;
    _syncPipTicker();
    _syncFrameConsumer('pip-auto-enter');
    DiagProbe.event('pip-auto-enter', <String, Object?>{
      'textureId': _player.videoController?.id.value,
      'isPlaying': _player.playerStatus.isPlaying,
      'positionMs': _player.positionInMilliseconds,
      'autoArmed': _pipAutoArmed,
    });
  }

  /// 按 Home 退后台时显式请求原生启动画中画。
  ///
  /// 本插件的 contentSource 是 `AVSampleBufferDisplayLayer`，
  /// `canStartPictureInPictureAutomaticallyFromInline` 只对 AVPlayerLayer
  /// 可靠生效，只 arm 不请求的话小窗永远不会自己起来。
  void _requestPipAutoEnterOnBackground(String reason) {
    if (_disposed || _leaving || !mounted) return;
    if (!_pipAutoArmed || _pipStartRequested) return;
    if (!_player.playerStatus.isPlaying) return;
    if (Platform.isAndroid) {
      if (!PiliAndroidHelper.isPipAvailable) return;
      _pipStartRequested = true;
      // 已经离开前台，直接用 autoEnter:false 请求系统进入小窗；SDK < 31
      // 的原生 autoEnter 不支持，但 enterPictureInPictureMode 仍可用。
      _player.enterPip(autoEnter: false);
      DiagProbe.event('android-pip-arm', <String, Object?>{
        'allow': true,
        'reason': reason,
        'action': 'start',
        'isPlaying': _player.playerStatus.isPlaying,
        'positionMs': _player.positionInMilliseconds,
        'textureId': _player.videoController?.id.value,
      });
      return;
    }
    if (IOSPipHelper.isActive || !IOSPipHelper.isAvailable) return;
    _pipStartRequested = true;
    IOSPipHelper.requestStart();
    DiagProbe.event('pip-auto-start', <String, Object?>{
      'reason': reason,
      'textureId': _player.videoController?.id.value,
      'isPlaying': _player.playerStatus.isPlaying,
      'positionMs': _player.positionInMilliseconds,
      'autoArmed': _pipAutoArmed,
      'pipActive': IOSPipHelper.isActive,
    });
  }

  Future<void> _pushPipLiteMode([bool? value]) async {
    try {
      await _pipChannel.invokeMethod<void>('update', <String, Object>{
        'pipLite': value ?? _pipLite,
      });
    } catch (_) {}
  }

  /// 诊断包专用：把 Documents 里的 trace / 采样打成 zip 并弹系统分享面板。
  Future<void> _exportDiagnostics() async {
    final path = await DiagProbe.exportAndShare();
    if (!mounted) return;
    SmartDialog.showToast(
      path == null ? '没有可导出的诊断文件' : '诊断包已生成：${path.split('/').last}',
    );
  }

  /// 启动画中画状态推送。
  ///
  /// PiP 活跃时每 500ms 推一次 position，原生 timebase 才会前进；只在进入
  /// 画中画时推一次的话，老机型依旧会卡帧。非活跃时 [_publishPipState]
  /// 只在状态变化时真正下发，不再每 500ms 走一次 method channel。
  bool get _pipShouldTick =>
      !Platform.isAndroid && (_pipAutoArmed || IOSPipHelper.isActive);

  /// 只在 PiP armed / active 时跑 ticker，正常前台播放不产生 500ms 定时器。
  void _syncPipTicker() {
    if (_pipShouldTick) {
      _startPipTicker();
    } else {
      _stopPipTicker();
    }
  }

  void _startPipTicker() {
    _pipTicker ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      _syncFrameConsumer('pip-tick');
      // 原生小窗可能在页面不知情时结束：发现不再需要就自行停掉。
      if (!_pipShouldTick) {
        _stopPipTicker();
        return;
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_lastPipTickMs != 0) {
        final gapMs = nowMs - _lastPipTickMs;
        if (gapMs > 300) {
          DiagProbe.event('ticker-gap', <String, Object?>{
            'gapMs': gapMs,
            'intervalMs': 500,
          });
        }
      }
      _lastPipTickMs = nowMs;
      _publishPipState();
    });
  }

  void _stopPipTicker() {
    _pipTicker?.cancel();
    _pipTicker = null;
    _lastPipTickMs = 0;
  }

  /// iOS PiP 期间把页内视频层压到最小，但保留一个纹理消费者。
  ///
  /// 不能完全摘掉 `Texture`：这个 media_kit fork 的 mpv 渲染回调依赖
  /// Flutter 侧持续请求纹理，一旦没有任何消费者，`textureFrameAvailable`
  /// 会长时间不再触发，小窗只能反复回放 hold 的最后一帧。这里改由
  /// [_video] 挂一个 2×2 的 `Texture`：只多一层极小合成，不做整页逐帧
  /// 重绘，同时保证纹理仍被按帧拉取。PiP 结束（[IOSPipHelper.isActive]
  /// 变假）后下一次同步会恢复整块视频层，返回播放页不会黑屏。
  ///
  /// 退后台请求 PiP 的那一段做乐观压制：Dart 在后台可能被挂起，等不到
  /// active 回调；回到前台且 PiP 没起来时会立即恢复。
  void _syncFrameConsumer(String reason) {
    if (_disposed) return;
    if (Platform.isAndroid) {
      // Android 的 PiP 是整个 Activity 进入小窗，Flutter texture 仍是唯一
      // 画面来源；不能套用 iOS 的停页内采样逻辑，否则小窗会变黑。
      DiagProbe.frontFramePulling = true;
      DiagProbe.pipFrameKeepAlive = false;
      if (_pipFrameSuppressed) {
        if (mounted) {
          setState(() => _pipFrameSuppressed = false);
        } else {
          _pipFrameSuppressed = false;
        }
      }
      return;
    }
    final pipActive = IOSPipHelper.isActive;
    final wantSuppress =
        pipActive ||
        (_appInBackground && (_pipAutoArmed || _pipStartRequested));
    DiagProbe.frontFramePulling = !wantSuppress;
    DiagProbe.pipFrameKeepAlive = wantSuppress;
    if (wantSuppress != _pipFrameSuppressed) {
      if (mounted) {
        setState(() => _pipFrameSuppressed = wantSuppress);
      } else {
        _pipFrameSuppressed = wantSuppress;
      }
      DiagProbe.event('frame-consumer', <String, Object?>{
        'mode': wantSuppress ? 'pip-only' : 'inline',
        'pipActive': pipActive,
        'frontFramePull': !wantSuppress,
        'keepAliveConsumer': wantSuppress,
        'appPaused': _appInBackground,
        'reason': reason,
        'textureId': _player.videoController?.id.value,
        'isPlaying': _player.playerStatus.isPlaying,
      });
    }
    if (!wantSuppress) {
      _pipFrameWatch?.cancel();
      _pipFrameWatch = null;
    } else if (pipActive && !_appInBackground) {
      _watchPipFrameConsumer();
    }
  }

  /// 原生要等 `didActivate` 才真正关掉小窗；只靠 500ms 的 PiP ticker 最坏
  /// 会让返回播放页黑 0.5s。这里用 120ms 的有界轮询，active 一变假立即
  /// 恢复内嵌视频层，最多跑 3s。
  void _watchPipFrameConsumer() {
    if (_pipFrameWatch != null) return;
    var ticks = 0;
    _pipFrameWatch = Timer.periodic(const Duration(milliseconds: 120), (timer) {
      if (_disposed || _leaving) {
        timer.cancel();
        _pipFrameWatch = null;
        return;
      }
      ticks += 1;
      _syncFrameConsumer('pip-stop-watch');
      if (!IOSPipHelper.isActive || ticks >= 25) {
        timer.cancel();
        _pipFrameWatch = null;
      }
    });
  }

  /// 字段形状与 pl_player 的 `_iosPipState()` 对齐；position/duration 用毫秒。
  void _publishPipState([int? positionMs]) {
    if (_disposed || !mounted || !IOSPipHelper.needsUpdate) return;
    final isPlaying = _player.playerStatus.isPlaying;
    final isBuffering = _player.isBuffering.value;
    final isLive = _player.isLive;
    final duration = _player.durationInMilliseconds;
    final speed = _player.playbackSpeed;
    // position 不参与签名：非 PiP 时它每拍都在变，算进去等于没降频。
    // 显式传入 positionMs 的调用（seek / 进入 PiP）仍强制下发一次。
    final sig = Object.hash(
      isPlaying,
      isBuffering,
      isLive,
      duration,
      speed,
      _pipLite,
    );
    if (!IOSPipHelper.isActive &&
        positionMs == null &&
        sig == _lastPipStateSig) {
      return;
    }
    _lastPipStateSig = sig;
    IOSPipHelper.update(<String, Object>{
      'isPlaying': isPlaying,
      'isBuffering': isBuffering,
      'isLive': isLive,
      'position': positionMs ?? _player.positionInMilliseconds,
      'duration': duration,
      'speed': speed,
      'pipLite': _pipLite,
    });
  }

  /// 锁屏/控制中心事件是否还能安全地驱动本页播放器。
  bool _canDriveBackground() =>
      mounted &&
      !_disposed &&
      !_leaving &&
      videoPlayerServiceHandler != null;

  Future<void> _bgRemotePlay() {
    if (!_canDriveBackground()) return Future<void>.value();
    if (_player.playerStatus.isPlaying) {
      _publishBackgroundState();
      return Future<void>.value();
    }
    return _togglePlay();
  }

  Future<void> _bgRemotePause() {
    if (!_canDriveBackground()) return Future<void>.value();
    if (!_player.playerStatus.isPlaying) {
      _publishBackgroundState();
      return Future<void>.value();
    }
    return _togglePlay();
  }

  Future<void> _bgRemoteSeek(Duration position) async {
    if (!_canDriveBackground()) return;
    try {
      await _player.seekTo(position);
    } catch (_) {
      // 切条/退出时播放器可能已被释放，seek 失败不影响后续状态刷新。
    }
    if (!_canDriveBackground()) return;
    _pushProgress(force: true);
    _publishPipState(position.inMilliseconds);
    _publishBackgroundState(positionMs: position.inMilliseconds);
  }

  void _bgRemoteNext() {
    if (!_canDriveBackground()) return;
    unawaited(_next(source: 'next'));
  }

  void _bgRemotePrevious() {
    if (!_canDriveBackground()) return;
    unawaited(_previous());
  }

  bool _bgRemoteIsPlaying() =>
      _canDriveBackground() && _player.playerStatus.isPlaying;

  /// 把锁屏/控制中心的远程控制指向本页播放器。
  ///
  /// 此前只写入了 mediaItem，卡片能出现，但 play()/pause() 仍回落到
  /// PlPlayerController（B站控制器），按钮点了没反应。这里只绑定一次并
  /// 保存原值，退出时原样恢复，避免污染 B站播放页。
  void _bindBackgroundRemoteControls() {
    final handler = videoPlayerServiceHandler;
    if (handler == null || _bgRemoteControlsBound) return;
    _savedBgIsPlaying = handler.isPlaying;
    _savedBgOnPlay = handler.onPlay;
    _savedBgOnPause = handler.onPause;
    _savedBgOnSeek = handler.onSeek;
    _savedBgOnSkipToNext = handler.onSkipToNext;
    _savedBgOnSkipToPrevious = handler.onSkipToPrevious;
    handler
      ..isPlaying = _bgRemoteIsPlaying
      ..onPlay = _bgRemotePlay
      ..onPause = _bgRemotePause
      ..onSeek = _bgRemoteSeek
      ..onSkipToNext = _bgRemoteNext
      ..onSkipToPrevious = _bgRemotePrevious;
    _bgRemoteControlsBound = true;
  }

  /// 刷新锁屏/控制中心卡片的状态与可用控件。
  ///
  /// 不传 debugLabel：`onVideoPaused` 那一支会让 onUpdateState 直接返回，
  /// 等于这次刷新白做。
  void _publishBackgroundState({PlayerStatus? status, int? positionMs}) {
    if (!_canDriveBackground()) return;
    final handler = videoPlayerServiceHandler;
    if (handler == null || !_bgKeepAliveApplied) return;
    handler.onUpdateState(
      status ?? _player.playerStatus,
      _player.isBuffering.value,
      false,
      position: Duration(
        milliseconds: positionMs ?? _player.positionInMilliseconds,
      ),
      speed: 1.0,
    );
    _syncBackgroundControls();
  }

  /// 锁屏/控制中心只会点亮 `PlaybackState.controls` 里列出的动作。
  /// handler 默认给的是快退/播放/快进，iOS 的上一首/下一首因此不会出现；
  /// 抖音是上下切条，这里补成「上一条 / 播放暂停 / 下一条」。
  /// 退出页面时 `clearIfNeeded()` 会把控件清空，不影响 B站。
  void _syncBackgroundControls() {
    final handler = videoPlayerServiceHandler;
    if (handler == null) return;
    final playing = handler.playbackState.value.playing;
    handler.playbackState.add(
      handler.playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
      ),
    );
  }

  /// 对齐 B站：临时打开 enableBackgroundPlay，并用现有的
  /// `onVideoDetailChange` 写入 mediaItem（内部 `_item` 非空后，
  /// `onUpdateState` 才会驱动音频会话）。退出页面时恢复原值。
  void _applyBackgroundKeepAlive() {
    final handler = videoPlayerServiceHandler;
    if (handler == null) return;
    if (!_bgKeepAliveApplied) {
      _savedEnableBackgroundPlay = handler.enableBackgroundPlay;
      handler.enableBackgroundPlay = true;
      _bgKeepAliveApplied = true;
    }
    final entry = _current;
    // 切条时先摘掉本页上一条，避免 _item 里越叠越多。
    handler.onVideoDetailDispose(_bgTag);
    handler.onVideoDetailChange(
      Part(part: entry.title, duration: (entry.durationMs / 1000).round()),
      0,
      _bgTag,
      artist: entry.author,
      cover: entry.cover,
    );
    _bindBackgroundRemoteControls();
    // mediaItem 写入后 onUpdateState 才生效，这里立刻推一次，
    // 让卡片从「无回调」切换到真实的暂停/播放状态。
    _publishBackgroundState();
    DiagProbe.event('bg-keepalive', <String, Object?>{
      'enabled': handler.enableBackgroundPlay,
      'hasMediaItem': handler.mediaItem.value != null,
      'textureId': _player.videoController?.id.value,
      'entryKey': entry.key,
    });
  }

  void _releaseBackgroundKeepAlive() {
    final handler = videoPlayerServiceHandler;
    // 先把回调恢复成进入前的值（通常是 null），再摘 mediaItem。
    if (handler != null && _bgRemoteControlsBound) {
      handler
        ..isPlaying = _savedBgIsPlaying
        ..onPlay = _savedBgOnPlay
        ..onPause = _savedBgOnPause
        ..onSeek = _savedBgOnSeek
        ..onSkipToNext = _savedBgOnSkipToNext
        ..onSkipToPrevious = _savedBgOnSkipToPrevious;
      _bgRemoteControlsBound = false;
      _savedBgIsPlaying = null;
      _savedBgOnPlay = null;
      _savedBgOnPause = null;
      _savedBgOnSeek = null;
      _savedBgOnSkipToNext = null;
      _savedBgOnSkipToPrevious = null;
    }
    if (handler == null || !_bgKeepAliveApplied) return;
    handler.onVideoDetailDispose(_bgTag);
    // 本页 item 已摘除；顺手清掉它留下的 Now Playing / 播放状态，
    // 避免退出播放页后媒体通知还显示抖音条目。
    handler.clearIfNeeded();
    final saved = _savedEnableBackgroundPlay;
    if (saved != null) handler.enableBackgroundPlay = saved;
    _bgKeepAliveApplied = false;
    _savedEnableBackgroundPlay = null;
  }

  /// 进/回后台各记一条，直接观察 textureId 是否变化；copyPixelBuffer
  /// 返回 nil 或内容重复由原生 pip_trace 的 frame/stale-source 记录。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final textureId = _player.videoController?.id.value;
    _appPaused =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive;
    _appInBackground =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _bgTextureId = textureId;
      _requestPipAutoEnterOnBackground('background-${state.name}');
      DiagProbe.event('bg-enter', <String, Object?>{
        'textureId': textureId,
        'positionMs': _player.positionInMilliseconds,
        'isPlaying': _player.playerStatus.isPlaying,
        'pipActive': IOSPipHelper.isActive,
        'keepAlive': _bgKeepAliveApplied,
      });
    } else if (state == AppLifecycleState.inactive) {
      _requestPipAutoEnterOnBackground('inactive');
    } else if (state == AppLifecycleState.resumed) {
      _appPaused = false;
      // 上一次后台请求可能失败（原生 2s 兜底会回 active:false）；回到前台
      // 清掉请求标记，下次按 Home 还能再试一次。
      _pipStartRequested = false;
      if (_player.playerStatus.isPlaying) {
        _armPipAutoEnter('resume');
      }
      DiagProbe.event('bg-return', <String, Object?>{
        'textureId': textureId,
        'previousTextureId': _bgTextureId,
        'textureChanged': textureId != _bgTextureId,
        'positionMs': _player.positionInMilliseconds,
        'isPlaying': _player.playerStatus.isPlaying,
        'pipActive': IOSPipHelper.isActive,
      });
      // 看门狗在后台时只记录不重建；回前台后如果仍然没有首帧，补一次
      // 判定（_onFirstFrameWatchdog 会先确认当前状态确实没有画面）。
      if (!_firstFrameSeen &&
          _watchdogSession == _openSession &&
          _watchdogSession >= 0 &&
          !_disposed &&
          !_leaving) {
        _firstFrameWatchdog?.cancel();
        _firstFrameWatchdog = Timer(
          const Duration(milliseconds: 1000),
          () => _onFirstFrameWatchdog(_watchdogSession),
        );
      }
      _bgTextureId = null;
    }
    _syncFrameConsumer('lifecycle-${state.name}');
  }

  /// 打开播放模式选择面板。六种模式一次列全，点哪项切哪项；
  /// 随机也作为一个普通选项，不再靠反复点击循环过去。
  void _openPlayModePanel() {
    _openPanel(_PlayerPanel.playMode);
  }

  /// 直接应用选中的播放模式并落盘。`null` 表示随机播放。
  void _selectPlayMode(PlayRepeat? repeat) {
    _prefetchKey = null;
    _prefetchFuture = null;
    setState(() {
      if (repeat == null) {
        _shuffle = true;
        _repeat = PlayRepeat.listCycle;
        _deck.clear();
        _refillDeck();
      } else {
        _shuffle = false;
        _repeat = repeat;
      }
    });
    _closePanel();
    unawaited(_persistPlayMode());
    SmartDialog.showToast('播放模式：$_playModeLabel');
    _prefetchNext();
  }

  /// 下次进播放页沿用上次选中的模式。
  void _restorePlayMode() {
    try {
      final saved = GStorage.video.get(_playModeStoreKey);
      if (saved is! int) return;
      if (saved == _shufflePlayModeCode) {
        _shuffle = true;
        _repeat = PlayRepeat.listCycle;
        return;
      }
      if (saved >= 0 && saved < PlayRepeat.values.length) {
        _repeat = PlayRepeat.values[saved];
        _shuffle = false;
      }
    } catch (_) {}
  }

  Future<void> _persistPlayMode() async {
    try {
      await GStorage.video.put(
        _playModeStoreKey,
        _shuffle ? _shufflePlayModeCode : _repeat.index,
      );
    } catch (_) {}
  }

  /// 还原「画面填充」偏好。没有落盘记录时保持默认的裁剪铺满。
  void _restoreVideoFit() {
    try {
      final saved = GStorage.video.get(_videoFitStoreKey);
      if (saved is bool) _fillScreen = saved;
    } catch (_) {}
  }

  Future<void> _persistVideoFit() async {
    try {
      await GStorage.video.put(_videoFitStoreKey, _fillScreen);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final entry = _current;
    final viewPadding = MediaQuery.viewPaddingOf(context);
    // PiP 精简布局：系统小窗只渲染视频画面，不构建标题/底栏/顶栏/边缘
    // 手势/面板。只在进出 PiP 时 setState 一次，PiP 期间不做逐帧重绘。
    if (_isPipLayout) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _video(),
      );
    }
    // 控件尺寸按窗口宽度分档：6S 紧凑、15PM 舒展、平板/横屏再放大。
    // 只缩放命中区和间距，图标始终 20px，避免窄屏被压成小点。
    final size = MediaQuery.sizeOf(context);
    final metrics = _PlayerUiMetrics.ofWidth(size.width);
    final double textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final double extra = (textScale - 1.0).clamp(0.0, 0.6).toDouble();
    final double topBarHeight = metrics.topBarHeight + extra * 8;
    final double bottomBarHeight = metrics.bottomBarHeight + extra * 8;
    final topInset = _chromeVisible ? viewPadding.top + topBarHeight : 0.0;
    final bottomInset = _chromeVisible
        ? viewPadding.bottom + bottomBarHeight
        : 0.0;
    // 底部蒙层至少占屏幕高度 8%；控件仍贴在安全区底部，不再像旧版
    // 那样整条栏高全涂黑、在控件下方留一块空黑边。
    final double bottomBackdropHeight =
        viewPadding.bottom + bottomBarHeight > size.height * 0.08
        ? viewPadding.bottom + bottomBarHeight
        : size.height * 0.08;
    return PopScope(
      // 系统返回手势 / 安卓返回键也要走收尾。注意这里是同步触发，
      // 不阻塞 pop，避免手势退出时同样被原生回调拖住。
      // 面板打开时先关面板，不直接退页。
      canPop: _panel == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(_shutdown());
        } else {
          _closePanel();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 视频永远铺满整屏，控件以半透明渐变叠在画面上。之前把视频
            // 上下各缩进一条栏高，竖屏短视频会在顶部/底部留下整块黑边，
            // 用户反复反馈的「上下多余空白」就是这一条。控件层仍是独立的
            // Positioned，命中测试按 Stack 逆序先到控件，不会互相截事件。
            Positioned.fill(child: _video()),
            // 亮度/音量/进度提示。IgnorePointer 保证它只负责显示，
            // 命中测试继续落到下面的视频手势层。
            _gestureOverlay(),
            // 边缘滑返回。放在视频层之后、控件栏之前：
            //
            // 1. 命中测试是逆序遍历，必须排在 `Positioned.fill` 的视频层后面，
            //    否则视频层会先接走这一条边缘上的指针，手势根本收不到。
            //    但也不能排到控件栏上面，否则会盖住左上角的返回按钮。
            // 2. 只用左边缘一小条，不要整屏。整屏的横向拖动会和按钮的 tap、
            //    视频的 onClick 一起进手势仲裁，拖一下就把点击吃掉。
            // 3. 上下要避开控件栏。返回按钮就在左上角，和边缘条在几何上
            //    重叠的话，手指压到它左半边就没有反应。沉浸式下 topInset /
            //    bottomInset 都是 0，这一条自然铺满整个高度。
            // 4. 沉浸式下也保留：控件收起后如果连侧滑都没有，用户只能先点
            //    画面唤回控件再滑，等于多一道手续。用 translucent 而不是
            //    opaque，这一条只拦横向拖动，轻点仍会落到视频层去切换控件，
            //    竖滑调亮度也照样能进视频层。
            Positioned(
              left: 0,
              top: topInset,
              bottom: bottomInset,
              width: _edgeSwipeWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (_) => _dragDx = 0,
                onHorizontalDragUpdate: (details) {
                  _dragDx += details.delta.dx;
                },
                onHorizontalDragEnd: (_) {
                  if (_dragDx > 40) _leave();
                  _dragDx = 0;
                },
                onHorizontalDragCancel: () => _dragDx = 0,
              ),
            ),
            // 控件栏必须给死高度。
            //
            // 之前是 `Positioned(top/left/right)` 不给 height，Stack 会传一个
            // 无界高度约束下来，里面的 Row 高度游离不定：控件区域算不准，
            // 点按能落在哪儿也跟着不确定。给了明确高度之后布局是确定的，
            // 命中测试区域也跟着确定。
            //
            // 安全区已经在 height 里算进去了，所以这里 SafeArea 只取方向、
            // 不再重复扣 inset（否则控件会被挤出可视区域，点也点不准）。
            if (_chromeVisible)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: viewPadding.top + topBarHeight,
                child: _chromeBackdrop(
                  child: SafeArea(
                    top: true,
                    bottom: false,
                    left: false,
                    right: false,
                    minimum: EdgeInsets.zero,
                    child: _topBar(entry, metrics),
                  ),
                ),
              ),
            if (_chromeVisible)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: bottomBackdropHeight,
                child: _chromeBackdrop(
                  bottom: true,
                  child: SafeArea(
                    top: false,
                    bottom: true,
                    left: false,
                    right: false,
                    minimum: EdgeInsets.zero,
                    child: _bottomBar(metrics),
                  ),
                ),
              ),
            if (_panel != null) _panelOverlay(),
          ],
        ),
      ),
    );
  }

  /// 控件层背景：顶部/底部向画面中间渐隐的黑色遮罩。
  ///
  /// 视频铺满全屏后，控件直接叠在画面上，纯黑底会重新切出一条「黑边」；
  /// 这里用单层线性渐变保证白字可读，同时让画面自然过渡到控件。不用模糊，
  /// 6S 上模糊每次重绘都要跑着色器。
  Widget _chromeBackdrop({required Widget child, bool bottom = false}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: bottom ? Alignment.bottomCenter : Alignment.topCenter,
          end: bottom ? Alignment.topCenter : Alignment.bottomCenter,
          colors: const <Color>[
            Color(0xCC000000),
            Color(0x66000000),
            Color(0x00000000),
          ],
          stops: const <double>[0.0, 0.55, 1.0],
        ),
      ),
      child: child,
    );
  }

  /// 左边缘滑返回的响应宽度。和 iOS 系统侧滑手势的识别区宽度接近，
  /// 足够手指起手，又不会伸到中间的按钮区域去抢事件。
  static const double _edgeSwipeWidth = 20;

  Future<void> _primeBrightness() async {
    if (_brightnessPrimed) return;
    try {
      double value;
      try {
        value = await ScreenBrightnessPlatform.instance.system;
        _brightnessIsApplication = false;
      } catch (_) {
        value = await ScreenBrightnessPlatform.instance.application;
        _brightnessIsApplication = true;
      }
      if (!mounted) return;
      _brightnessPrimed = true;
      _brightness = value.clamp(0.0, 1.0).toDouble();
      _player.brightness.value = _brightness;
    } catch (_) {}
  }

  Future<void> _primeVolume() async {
    if (_volumePrimed) return;
    try {
      final value = await FlutterVolumeController.getVolume();
      if (!mounted || value == null) return;
      _volumePrimed = true;
      _volume = value.clamp(0.0, _player.maxVolume).toDouble();
      _player.volume.value = _volume;
    } catch (_) {}
  }

  /// 亮度统一走 ScreenBrightnessPlatform：iOS 直接改系统亮度，
  /// 系统亮度不可写（例如安卓没给 WRITE_SETTINGS）时退回应用内亮度。
  Future<void> _applyBrightness(double value) async {
    _brightness = value;
    _player.brightness.value = value;
    try {
      await ScreenBrightnessPlatform.instance.setSystemScreenBrightness(value);
      _brightnessIsApplication = false;
    } catch (_) {
      try {
        await ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(
          value,
        );
        _brightnessIsApplication = true;
      } catch (_) {}
    }
  }

  void _onVerticalDragStart(DragStartDetails details) {
    final sw = Stopwatch()..start();
    final size = MediaQuery.sizeOf(context);
    final isLeft = details.localPosition.dx < size.width / 2;
    _swipeTarget = isLeft ? _SwipeTarget.brightness : _SwipeTarget.volume;
    _swipeStartY = details.localPosition.dy;
    _swipeStartValue = isLeft ? _brightness : _volume;
    // 在开始拖时算一次，拖动过程中不要再查 MediaQuery。
    _swipeRange = size.height * (isLeft ? 0.6 : 0.5);
    _publishSwipeHint(_swipeStartValue);
    sw.stop();
    _diagUiBlock('gesture', 'vertical-start', sw, throttleMs: 1000);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final sw = Stopwatch()..start();
    final target = _swipeTarget;
    if (target == null) return;
    final isBrightness = target == _SwipeTarget.brightness;
    final range = _swipeRange;
    final max = isBrightness ? 1.0 : _player.maxVolume;
    final value =
        (_swipeStartValue - (details.localPosition.dy - _swipeStartY) / range)
            .clamp(0.0, max)
            .toDouble();
    if (isBrightness) {
      // 拖动途中只改本地值，松手才写系统亮度。
      //
      // 之前这里每帧都调一次 setSystemScreenBrightness：那是带原生往返的
      // 系统级调用，6S 上按 60Hz 拖动等于每 16ms 打一次原生，整机都跟着卡。
      _brightness = value;
      _player.brightness.value = value;
    } else {
      _volume = value;
      unawaited(_player.setVolume(value, showIndicator: false));
    }
    _publishSwipeHint(value);
    sw.stop();
    _diagUiBlock('gesture', 'vertical', sw, throttleMs: 1000);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final sw = Stopwatch()..start();
    if (_swipeTarget == _SwipeTarget.brightness) {
      unawaited(_applyBrightness(_brightness));
    }
    _swipeTarget = null;
    _hideHintSoon();
    sw.stop();
    _diagUiBlock('gesture', 'vertical-end', sw, throttleMs: 1000);
  }

  void _onVerticalDragCancel() {
    _swipeTarget = null;
    _hideHintSoon();
  }

  /// 横向拖动只更新预览，松手才真正 seek，避免拖动途中反复冲缓冲。
  void _onHorizontalDragStart(DragStartDetails details) {
    final sw = Stopwatch()..start();
    final durationMs = _player.durationInMilliseconds;
    _seekDragging = durationMs > 0;
    if (!_seekDragging) return;
    var start = _player.positionInMilliseconds;
    if (start <= 0) start = _player.position.value * 1000;
    _seekStartMs = start.clamp(0, durationMs).toInt();
    _seekTargetMs = _seekStartMs;
    // 同样在开始拖时缓存，拖动途中不查 MediaQuery。
    _seekWidth = MediaQuery.sizeOf(context).width;
    _showSeekHint();
    sw.stop();
    _diagUiBlock('gesture', 'horizontal-start', sw, throttleMs: 1000);
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    final sw = Stopwatch()..start();
    if (!_seekDragging) return;
    final durationMs = _player.durationInMilliseconds;
    final width = _seekWidth;
    if (durationMs <= 0 || width <= 0) return;
    final deltaMs = (details.delta.dx / width * durationMs).round();
    _seekTargetMs = (_seekTargetMs + deltaMs).clamp(0, durationMs).toInt();
    _showSeekHint();
    sw.stop();
    _diagUiBlock('gesture', 'horizontal', sw, throttleMs: 1000);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final sw = Stopwatch()..start();
    if (!_seekDragging) return;
    _seekDragging = false;
    _player.position.value = _seekTargetMs ~/ 1000;
    unawaited(
      _player
          .seekTo(Duration(milliseconds: _seekTargetMs))
    );
    _pushProgress(force: true);
    _publishPipState(_seekTargetMs);
    _publishBackgroundState(positionMs: _seekTargetMs);
    _hideHintSoon();
    sw.stop();
    _diagUiBlock('gesture', 'horizontal-end', sw, throttleMs: 1000);
  }

  void _onHorizontalDragCancel() {
    if (!_seekDragging) return;
    _seekDragging = false;
    _hideHintSoon();
  }

  void _publishSwipeHint(double value) {
    final target = _swipeTarget;
    if (target == null) return;
    _gestureHintTimer?.cancel();
    if (target == _SwipeTarget.brightness) {
      _gestureHint.value = _GestureHint(
        icon: Icons.brightness_6,
        title: '亮度',
        detail: '${(value * 100).round()}%',
        progress: value,
      );
    } else {
      _gestureHint.value = _GestureHint(
        icon: value <= 0 ? Icons.volume_off : Icons.volume_up,
        title: '音量',
        detail: '${(value * 100).round()}%',
        progress: value,
      );
    }
  }

  void _showSeekHint() {
    final durationMs = _player.durationInMilliseconds;
    if (durationMs <= 0) return;
    final deltaMs = _seekTargetMs - _seekStartMs;
    final deltaText = DurationUtils.formatDuration(deltaMs.abs() ~/ 1000);
    _gestureHintTimer?.cancel();
    _gestureHint.value = _GestureHint(
      icon: deltaMs >= 0 ? Icons.fast_forward : Icons.fast_rewind,
      title: '进度',
      detail:
          '${DurationUtils.formatDuration(_seekTargetMs ~/ 1000)}'
          ' / ${DurationUtils.formatDuration(durationMs ~/ 1000)}'
          '  ${deltaMs >= 0 ? '+' : '-'}$deltaText',
      progress: (_seekTargetMs / durationMs).clamp(0.0, 1.0).toDouble(),
    );
  }

  void _hideHintSoon() {
    _gestureHintTimer?.cancel();
    _gestureHintTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) _gestureHint.value = null;
    });
  }

  Widget _video() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _open(_index, source: 'next'),
                child: const Text('重试'),
              ),
              TextButton(
                onPressed: () => unawaited(_next(source: 'next')),
                child: const Text('下一条'),
              ),
            ],
          ),
        ),
      );
    }
    final controller = _player.videoController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    // 画面填充：竖屏短视频用 contain 会在上下留出大片黑边。这里按
    // 「短边贴合屏幕宽度」放大，只裁掉少量边缘；横屏/旋转后的宽画面
    // 在 [_videoFitFor] 里自动退回 contain，避免把两侧裁掉大半。
    //
    // 视频宽高比只有首帧渲染后才拿得到（VideoController.rect 由渲染循环
    // 回填），用 ValueListenableBuilder 跟着 rect 更新一次，避免首帧前
    // 按「未知比例」定死填充方式。
    final video = Obx(
      () => Transform.flip(
        flipX: _player.flipX.value,
        flipY: _player.flipY.value,
        child: RepaintBoundary(
          child: ValueListenableBuilder<Rect?>(
            valueListenable: controller.rect,
            builder: (context, rect, _) {
              return ClipRect(
                child: FittedBox(
                  fit: _videoFitFor(rect),
                  alignment: Alignment.center,
                  child: SimpleVideo(
                    controller: controller,
                    fill: Colors.black,
                    aspectRatio: null,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    // PiP 活跃时页内不再显示整块视频，但必须保留一个纹理消费者：完全
    // 摘掉 `Texture` 后 Flutter 不再按帧取 buffer，mpv 的渲染回调会停，
    // 小窗只能回放 hold 的旧帧。这里用黑底铺满 + 2×2 `Texture` 占位，
    // 只让这一小块参与合成与重绘，不构成整页逐帧重绘。PiP 结束后
    // setState 重建 video，内嵌画面立即恢复。
    final displayVideo = _pipFrameSuppressed
        ? _pipKeepAliveVideo(controller)
        : video;
    return GestureDetector(
      // 和 B站播放页一致：双击暂停/播放，单击切换控件显隐（沉浸式）。
      //
      // 单击不直接控制播放：抖音/TikTok 用户习惯点一下看控件，直接暂停会
      // 和「双击暂停」打架。onTap 和 onDoubleTap 同时存在时，单击要等
      // 约 300ms 双击判定超时才派发——这里可以接受，因为单击只影响控件条，
      // 不影响播放是否继续。
      behavior: HitTestBehavior.opaque,
      onTap: _toggleChrome,
      onDoubleTap: () => unawaited(_togglePlay()),
      onVerticalDragStart: _onVerticalDragStart,
      onVerticalDragUpdate: _onVerticalDragUpdate,
      onVerticalDragEnd: _onVerticalDragEnd,
      onVerticalDragCancel: _onVerticalDragCancel,
      onHorizontalDragStart: _onHorizontalDragStart,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      onHorizontalDragCancel: _onHorizontalDragCancel,
      child: ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(
          // 结构和上游 pl_player/view/view.dart 对齐：RepaintBoundary →
          // FittedBox → SimpleVideo。
          //
          // RepaintBoundary 不是可有可无的：SimpleVideo 每帧都在
          // ListenableBuilder 里重建，没有它就会把重绘范围扩散到整个页面，
          // 6S 上表现为画面卡顿、主 isolate 被拖住。
          //
          // 这里不能再套 Center：Center 会把约束放松成 loose，FittedBox
          // 于是收缩成 SimpleVideo 的「原始尺寸」（texture 像素 / DPR），
          // 15PM 上就只剩屏幕中间一小块。SizedBox.expand 给 FittedBox 一个
          // 撑满可用区域的紧约束，contain 再把画面等比放大到区域内：既不
          // 拉伸，也不会出现四边大片黑边。
          //
          // FittedBox 的 alignment 默认是 center，fit 用 contain，和上游
          // videoFit 在竖屏下的 BoxFit.contain 一致；aspectRatio 传 null
          // 表示按 texture 实际像素比（上游是 videoFit.aspectRatio，抖音这
          // 条没有外部画质偏好，用真实比例最稳，避免拉伸）。
          //
          // 没旋转时不要再套 RotatedBox：它会给子树多一层 render object，
          // 每帧都要参与变换。轻量模式下这层完全省掉，需要旋转时才加回来。
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_pipLite && _quarterTurns == 0)
                displayVideo
              else
                RotatedBox(quarterTurns: _quarterTurns, child: displayVideo),
              // PiP 精简布局只保留视频画面，不叠加任何文案提示。
              if (!_isPipLayout)
                Obx(
                  () => _player.onlyPlayAudio.value
                      ? const IgnorePointer(child: _AudioOnlyBadge())
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// PiP 期间的最小纹理消费者。
  ///
  /// `Texture` 只要还在树上、还参与合成，引擎就会按帧调
  /// `copyPixelBuffer`，和它在屏幕上的大小无关。尺寸取 2×2 逻辑像素，
  /// 黑底保证用户看不到这块纹理；`RepaintBoundary` 把这层逐帧重绘
  /// 限制在 2×2 内，避免扩散到整页。
  Widget _pipKeepAliveVideo(VideoController controller) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        Positioned(
          left: 0,
          top: 0,
          width: 2,
          height: 2,
          child: RepaintBoundary(
            child: ValueListenableBuilder<int?>(
              valueListenable: controller.id,
              builder: (context, textureId, _) {
                if (textureId == null) return const SizedBox.shrink();
                return Texture(
                  textureId: textureId,
                  filterQuality: FilterQuality.none,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 当前视频的填充方式。
  ///
  /// 关闭「裁剪铺满」时始终 contain，保留完整画面；开启时竖屏/方形视频
  /// 用 cover 铺满，横屏视频（宽 > 高）铺满会裁掉两侧大半，退回 contain。
  /// 画面旋转 90°/270° 时宽高互换，按旋转后的比例判断。
  BoxFit _videoFitFor(Rect? rect) {
    if (!_fillScreen) return BoxFit.contain;
    if (rect == null || rect.width <= 0 || rect.height <= 0) {
      // 首帧前拿不到尺寸，先按铺满处理；拿到 rect 后会再重建一次。
      return BoxFit.cover;
    }
    final ratio = _quarterTurns.isOdd
        ? rect.height / rect.width
        : rect.width / rect.height;
    return ratio > 1.0 ? BoxFit.contain : BoxFit.cover;
  }

  Widget _gestureOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<_GestureHint?>(
          valueListenable: _gestureHint,
          builder: (context, hint, child) {
            if (hint == null) return const SizedBox.shrink();
            // 轻量浮层：贴在顶部栏下方居中，不压画面中心，也不会被顶栏
            // 盖住。只做提示，不接管触摸（外层 IgnorePointer），上下滑
            // 亮度/音量、横滑 seek 都不受影响。
            final topInset = MediaQuery.viewPaddingOf(context).top;
            final metrics = _PlayerUiMetrics.ofWidth(
              MediaQuery.sizeOf(context).width,
            );
            return SafeArea(
              minimum: EdgeInsets.only(
                top: topInset + metrics.topBarHeight + 6,
                left: 24,
                right: 24,
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.58),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: SizedBox(
                      width: 168,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(hint.icon, color: Colors.white, size: 18),
                              const SizedBox(width: 6),
                              Text(
                                hint.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hint.detail,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                          if (hint.progress case final progress?) ...[
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 2,
                                backgroundColor: Colors.white24,
                                valueColor:
                                    const AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 控件层。
  ///
  /// 这里曾经套过一层 `AbsorbPointer`，注释写的是「防止手指漏给视频层」，
  /// 这是错的、而且后果很严重：`AbsorbPointer` 默认 `absorbing: true`，
  /// 语义是「命中测试在本节点终止，子树拿不到任何指针事件」，也就是把整排
  /// 控件（返回、暂停、上/下一条、画中画、随机）全部禁用掉。用户看到的就是
  /// 「页面像卡死、按钮全失灵、返回不了」。
  ///
  /// 不需要任何拦截：控件层是 Stack 里位于视频层之上的独立 Positioned，
  /// 本来就会吃掉自己区域内的触摸，命中测试按 Stack 逆序走，先到控件层。
  Widget _controls(Widget child, _PlayerUiMetrics metrics) {
    return Padding(
      // 上下只留 2pt，把多余高度还给视频区；左右留白随宽度分档。
      padding: EdgeInsets.symmetric(horizontal: metrics.edge, vertical: 2),
      child: child,
    );
  }

  /// 顶栏只放两组：左端返回，右端动作组 + 更多。
  ///
  /// 动作组不铺满整行，而是按宽度和优先级挑出放得下的图标；放不下的
  /// 收进「更多」面板，窄屏不会把图标压小，也不会出现横向滚动条。
  Widget _topBar(QueueEntry entry, _PlayerUiMetrics metrics) {
    final inline = _inlineActions(MediaQuery.sizeOf(context).width);
    return _controls(
      Center(
        child: PlayerBar(
          left: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ComBtn(
                icon: const Icon(
                  Icons.keyboard_arrow_down,
                  color: Colors.white,
                  size: _PlayerUiMetrics.icon,
                ),
                // 返回必须永远可用，不能等收尾完成才响应——收尾里如果等原生
                // 关小窗卡住，用户看到的就是「点了没反应」。_leave 是同步的，
                // 收尾在它内部以 unawaited 方式启动。
                onTap: _leave,
                tooltip: '返回',
                width: metrics.hit,
                height: metrics.hit,
              ),
            ],
          ),
          title: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openPanel(_PlayerPanel.title),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.expand_more,
                    size: 16,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
          right: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in inline) ...[
                _actionButton(action, metrics),
                SizedBox(width: metrics.gap),
              ],
              ComBtn(
                icon: const Icon(
                  Icons.more_horiz,
                  color: Colors.white,
                  size: _PlayerUiMetrics.icon,
                ),
                onTap: () => _openPanel(_PlayerPanel.more),
                tooltip: '更多设置',
                width: metrics.hit,
                height: metrics.hit,
              ),
            ],
          ),
        ),
      ),
      metrics,
    );
  }

  /// 底栏只保留进度条和时间，不再挂第二排动作图标。
  ///
  /// 内容贴安全区底部，由外层至少 8% 屏高的渐变蒙层托底；position 回调
  /// 只重建 `_progress` 这一小块，不刷新整页。
  Widget _bottomBar(_PlayerUiMetrics metrics) {
    return _controls(
      Align(
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<_PlaybackProgress>(
              valueListenable: _progress,
              builder: (context, progress, _) {
                return Row(
                  children: [
                    _timeText(progress.position, Colors.white),
                    SizedBox(width: metrics.gap),
                    Expanded(
                      child: ProgressBar(
                        progress: progress.position,
                        buffered: progress.buffered,
                        total: progress.duration,
                        // 已播 / 缓冲 / 未播三段颜色拉开，4px 轨道在深色
                        // 画面上也能看清；拖动时只画纯色圆点。
                        baseBarColor: const Color(0x3DFFFFFF),
                        progressBarColor: Colors.white,
                        bufferedBarColor: const Color(0x8AFFFFFF),
                        thumbColor: Colors.white,
                        // 柔光半径等于手柄半径时不会绘制，颜色仅为满足
                        // 必填参数。
                        thumbGlowColor: Colors.transparent,
                        barHeight: 4,
                        thumbRadius: 6,
                        thumbGlowRadius: 6,
                        // RenderProgressBar 只有 onDragStart/onHover 非空时
                        // 才参与命中测试，否则整条进度条点不动。空回调只为
                        // 了可拖。
                        onDragStart: (_) {},
                        onSeek: (milliseconds) {
                          _player.position.value = milliseconds ~/ 1000;
                          unawaited(
                            _player.seekTo(
                              Duration(milliseconds: milliseconds),
                            ),
                          );
                          _pushProgress(force: true);
                          _publishPipState(milliseconds);
                          _publishBackgroundState(positionMs: milliseconds);
                        },
                      ),
                    ),
                    SizedBox(width: metrics.gap),
                    _timeText(progress.duration, Colors.white70),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      metrics,
    );
  }

  /// 按宽度挑动作：从高优先级开始累加，直到放不下或到达本档上限。
  ///
  /// 始终为返回和「更多」留位置，标题至少保留 `_titleMinWidth`，所以
  /// 右端分组不会把标题挤没，也不会触发 PlayerBar 的等比压缩。
  List<_PlayerAction> _inlineActions(double width) {
    final metrics = _PlayerUiMetrics.ofWidth(width);
    final double available =
        width -
        metrics.edge * 2 -
        metrics.hit * 2 -
        metrics.gap -
        _titleMinWidth;
    final result = <_PlayerAction>[];
    double used = 0;
    for (final action in _PlayerAction.values) {
      if (result.length >= metrics.inlineCap) break;
      final double cost = result.isEmpty
          ? metrics.hit
          : metrics.hit + metrics.gap;
      if (used + cost > available) break;
      used += cost;
      result.add(action);
    }
    return result;
  }

  List<_PlayerAction> _overflowActions(double width) {
    final inline = _inlineActions(width);
    return _PlayerAction.values
        .where((action) => !inline.contains(action))
        .toList(growable: false);
  }

  Widget _actionButton(_PlayerAction action, _PlayerUiMetrics metrics) {
    if (action == _PlayerAction.audioOnly) {
      // 听音频状态由 Rx 驱动，单独包一层 Obx，失败不会连带整条顶栏重建。
      return Obx(() => _actionButtonBody(action, metrics));
    }
    return _actionButtonBody(action, metrics);
  }

  Widget _actionButtonBody(_PlayerAction action, _PlayerUiMetrics metrics) {
    final color = switch (action) {
      _PlayerAction.playMode => _playModeColor,
      _PlayerAction.audioOnly => _player.onlyPlayAudio.value
          ? Colors.lightBlueAccent
          : Colors.white,
      _ => Colors.white,
    };
    return ComBtn(
      icon: Icon(
        _actionIcon(action),
        color: color,
        size: _PlayerUiMetrics.icon,
      ),
      onTap: () => _runAction(action),
      // 长按旋转键进入镜像面板；单击始终是一键 +90°，不再走两步面板。
      onLongPress: action == _PlayerAction.rotate
          ? () => _openPanel(_PlayerPanel.rotateFlip)
          : null,
      tooltip: _actionTooltip(action),
      width: metrics.hit,
      height: metrics.hit,
    );
  }

  IconData _actionIcon(_PlayerAction action) {
    return switch (action) {
      _PlayerAction.playlist => Icons.queue_music,
      _PlayerAction.comments => Icons.chat_bubble_outline,
      _PlayerAction.pip => Icons.picture_in_picture_alt_outlined,
      _PlayerAction.quality => Icons.high_quality_outlined,
      _PlayerAction.playMode => _playModeIcon,
      _PlayerAction.subtitle => Icons.subtitles_outlined,
      _PlayerAction.audioQuality => Icons.album_outlined,
      _PlayerAction.decode => Icons.memory_outlined,
      _PlayerAction.rotate => Icons.screen_rotation_alt_outlined,
      _PlayerAction.cast => Icons.cast,
      _PlayerAction.audioOnly => _player.onlyPlayAudio.value
          ? Icons.headphones
          : Icons.headphones_outlined,
    };
  }

  String _actionTooltip(_PlayerAction action) {
    return switch (action) {
      _PlayerAction.playlist => '播放列表',
      _PlayerAction.comments => '弹幕 / 评论',
      _PlayerAction.pip => '画中画',
      _PlayerAction.quality => '画质',
      _PlayerAction.playMode => '循环 / $_playModeLabel',
      _PlayerAction.subtitle => '字幕',
      _PlayerAction.audioQuality => '音质',
      _PlayerAction.decode => '解码',
      _PlayerAction.rotate => '旋转 90°（长按镜像）',
      _PlayerAction.cast => '投屏',
      _PlayerAction.audioOnly => '听音频',
    };
  }

  String _actionTitle(_PlayerAction action) {
    return switch (action) {
      _PlayerAction.playlist => '播放列表',
      _PlayerAction.comments => '弹幕 / 评论',
      _PlayerAction.pip => '画中画',
      _PlayerAction.quality => '画质',
      _PlayerAction.playMode => '播放模式',
      _PlayerAction.subtitle => '字幕',
      _PlayerAction.audioQuality => '音质',
      _PlayerAction.decode => '解码',
      _PlayerAction.rotate => '画面旋转',
      _PlayerAction.cast => '投屏',
      _PlayerAction.audioOnly => '听音频',
    };
  }

  String? _actionSubtitle(_PlayerAction action) {
    return switch (action) {
      _PlayerAction.quality => '接口未提供分辨率档位',
      _PlayerAction.playMode => '当前：$_playModeLabel',
      _PlayerAction.rotate => '${_quarterTurns * 90}°',
      _PlayerAction.audioOnly => _player.onlyPlayAudio.value
          ? '已开启 · 只保留声音'
          : '关闭画面，只保留声音',
      _ => null,
    };
  }

  /// 顶栏图标和「更多」里的收纳项走同一个动作入口。
  void _runAction(_PlayerAction action) {
    switch (action) {
      case _PlayerAction.playlist:
        _closePanel();
        unawaited(_openPlaylist());
      case _PlayerAction.comments:
        _openPanel(_PlayerPanel.comments);
      case _PlayerAction.pip:
        _closePanel();
        unawaited(_enterPip());
      case _PlayerAction.quality:
        _openPanel(_PlayerPanel.quality);
      case _PlayerAction.audioQuality:
        _openPanel(_PlayerPanel.audioQuality);
      case _PlayerAction.decode:
        _openPanel(_PlayerPanel.decode);
      case _PlayerAction.playMode:
        _openPlayModePanel();
      case _PlayerAction.subtitle:
        _openPanel(_PlayerPanel.subtitle);
      case _PlayerAction.rotate:
        _closePanel();
        _rotateVideo();
      case _PlayerAction.cast:
        _closePanel();
        _castToDevice();
      case _PlayerAction.audioOnly:
        _toggleOnlyAudio();
    }
  }

  Widget _actionSheetTile(_PlayerAction action) {
    return _sheetTile(
      icon: _actionIcon(action),
      title: _actionTitle(action),
      subtitle: _actionSubtitle(action),
      onTap: () => _runAction(action),
    );
  }

  /// 标题在顶栏至少保留的宽度。
  static const double _titleMinWidth = 96;

  /// 投屏：把当前已经起播的直链交给 DLNA 页。没有地址时明确提示，
  /// 不做「按了没反应」。
  void _castToDevice() {
    final url = _currentMediaUrl;
    if (url == null || url.isEmpty) {
      SmartDialog.showToast('当前视频还没有可投屏的播放地址');
      return;
    }
    Get.toNamed(
      '/dlna',
      parameters: <String, String>{
        'url': url,
        'title': _currentMediaTitle,
      },
    );
  }

  /// 听音频：只关视频轨，音频继续。该来源是单条 mp4，没有独立音轨档位，
  /// 所以切回来时只恢复视频轨，不做音轨切换。
  void _toggleOnlyAudio() {
    final next = !_player.onlyPlayAudio.value;
    _player.onlyPlayAudio.value = next;
    try {
      _player.videoPlayerController?.setProperty(
        'file-local-options/vid',
        next ? 'no' : 'auto',
      );
    } catch (_) {}
    setState(() {});
    SmartDialog.showToast(
      next ? '听音频模式（该来源无独立音轨）' : '已恢复画面',
    );
  }

  /// 进度条两端的时间文字。等宽数字，避免播放时整行左右抖动。
  Widget _timeText(int seconds, Color color) {
    return Text(
      DurationUtils.formatDuration(seconds),
      style: TextStyle(
        color: color,
        fontSize: 11,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  void _rotateVideo() {
    setState(() => _quarterTurns = (_quarterTurns + 1) % 4);
  }

  /// mpv 采样值统一转文本：null / 空串都当「没读到」，面板显示占位而不是
  /// 空白，避免用户以为信息丢了。
  String? _mpvText(Object? value) {
    if (value == null) return null;
    final text = '$value';
    return text.isEmpty || text == 'null' ? null : text;
  }

  /// 点击画面：切换沉浸式。
  ///
  /// 只挂在视频层的 onTap 上。视频层和控件条在几何上不重叠，所以点按钮
  /// 不会顺带把控件收起来（B 站播放页那套是整屏一层手势，这里刻意不这么写）。
  void _toggleChrome() {
    if (_isPipLayout) return;
    setState(() => _chromeVisible = !_chromeVisible);
    _scheduleChromeHide();
  }

  /// 控件显示后 4 秒自动收起。用户又点一下可以立刻再收。
  void _scheduleChromeHide() {
    if (_isPipLayout) return;
    _chromeTimer?.cancel();
    if (!_chromeVisible) return;
    _chromeTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !_chromeVisible) return;
      setState(() => _chromeVisible = false);
    });
  }

  Widget _sheetHeader(String title) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
          const Spacer(),
          IconButton(
            onPressed: _closePanel,
            icon: const Icon(Icons.close, size: 18, color: Colors.white54),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _sheetTile({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Icon(icon, size: 20, color: Colors.white70),
      title: Text(
        title,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
      trailing: onTap == null
          ? null
          : const Icon(
              Icons.chevron_right,
              size: 18,
              color: Colors.white38,
            ),
    );
  }

  /// 打开页内面板。评论 / 画质 / 更多共用这一层。
  ///
  /// 画质和解码面板显示最近一次采样（开流/首帧/异常/导出）留下的缓存，
  /// 不因为点开面板再多读一轮 mpv。读不到就原样显示「未读到」。
  void _openPanel(_PlayerPanel panel) {
    _chromeTimer?.cancel();
    if (panel == _PlayerPanel.quality) {
      final snap = DiagProbe.cachedSnapshot();
      _qualityWidth = _mpvText(snap['video-params/w']);
      _qualityHeight = _mpvText(snap['video-params/h']);
    } else if (panel == _PlayerPanel.decode) {
      final snap = DiagProbe.cachedSnapshot();
      _decodeCurrent = _mpvText(snap['hwdec-current']) ?? '';
    }
    setState(() => _panel = panel);
    if (panel == _PlayerPanel.comments) {
      final video = _current.short;
      final platform =
          ShortVideoPlatform.fromId(video?.platform) ??
          ShortVideoPlatform.douyin;
      _diagComments(
        'opened',
        platform: platform,
        videoId: video?.videoId ?? '',
      );
      unawaited(_ensureComments());
    }
  }

  void _closePanel() {
    if (_panel == null) return;
    setState(() => _panel = null);
    _scheduleChromeHide();
  }

  void _resetComments() {
    _commentsSession++;
    _comments = const [];
    _commentsLoading = false;
    _commentsError = '';
    _commentsKey = '';
    _commentCaptionExpanded = true;
  }

  ({ShortVideoPlatform platform, String videoId, String key}) _commentTarget() {
    final video = _current.short;
    final platform =
        ShortVideoPlatform.fromId(video?.platform) ?? ShortVideoPlatform.douyin;
    final videoId = video?.videoId ?? '';
    return (
      platform: platform,
      videoId: videoId,
      key: '${platform.id}:$videoId',
    );
  }

  /// 视频一打开就在后台抓评论第一页。
  ///
  /// 放在 `_open` 里、和媒体解析并行：用户点开面板时要么直接命中缓存，
  /// 要么只等这个已经在途的请求，不再从零开始等 5-20 秒。
  /// 预取失败只写诊断，不弹提示、不改变播放状态。
  void _prefetchComments({required String source}) {
    if (_disposed || _leaving || !mounted) return;
    try {
      _prefetchCommentsInner(source: source);
    } catch (_) {
      // 评论预取是旁路：任何异常都不能让 _open 的 try 收尾成播放失败。
    }
  }

  void _prefetchCommentsInner({required String source}) {
    final target = _commentTarget();
    if (target.videoId.isEmpty) return;
    final key = target.key;
    final cached = _commentCache[key];
    if (cached != null) {
      if (_commentCacheFresh(cached)) {
        DiagProbe.event('comments-prefetch', <String, Object?>{
          'key': key,
          'hit': true,
          'elapsedMs': 0,
          'count': cached.list.length,
          'state': 'cache-hit',
          'source': source,
        });
        return;
      }
      _commentCache.remove(key);
    }
    if (_commentRequests.containsKey(key)) {
      DiagProbe.event('comments-prefetch', <String, Object?>{
        'key': key,
        'hit': false,
        'elapsedMs': 0,
        'count': null,
        'state': 'join',
        'source': source,
      });
      return;
    }
    if (_commentRequests.length >= _maxCommentPrefetchInFlight) {
      DiagProbe.event('comments-prefetch', <String, Object?>{
        'key': key,
        'hit': false,
        'elapsedMs': 0,
        'count': null,
        'state': 'skip-busy',
        'source': source,
        'inFlight': _commentRequests.length,
      });
      return;
    }
    unawaited(
      _loadCommentPage(
        key: key,
        platform: target.platform,
        videoId: target.videoId,
        source: 'prefetch-$source',
      ),
    );
  }

  bool _commentCacheFresh(_CommentPage page) =>
      DateTime.now().millisecondsSinceEpoch - page.fetchedAtMs <
      _commentCacheTtlMs;

  /// 打开评论面板时优先消费预取结果。
  ///
  /// 命中缓存直接渲染；未命中则显示骨架并等待（或复用）后台预取。
  /// 切条后 [_resetComments] 会让旧 session 的回包失效，绝不串到下一条。
  Future<void> _ensureComments({bool force = false}) async {
    if (!mounted) return;
    final target = _commentTarget();
    final platform = target.platform;
    final videoId = target.videoId;
    if (videoId.isEmpty) {
      setState(() {
        _commentsKey = '${platform.id}:';
        _comments = const [];
        _commentsLoading = false;
        _commentsError = 'unsupported';
      });
      _diagComments(
        'error',
        platform: platform,
        videoId: videoId,
        reason: 'unsupported',
      );
      return;
    }
    final key = target.key;
    if (!force) {
      if (key == _commentsKey &&
          (_commentsLoading ||
              _comments.isNotEmpty ||
              _commentsError.isNotEmpty)) {
        return;
      }
      final cached = _commentCache[key];
      if (cached != null && _commentCacheFresh(cached)) {
        _applyCommentPage(key, cached);
        DiagProbe.event('comments-prefetch', <String, Object?>{
          'key': key,
          'hit': true,
          'elapsedMs': 0,
          'count': cached.list.length,
          'state': 'cache-hit',
          'source': 'panel',
        });
        _diagCommentsForPage(cached, platform: platform, videoId: videoId);
        return;
      }
      if (cached != null) _commentCache.remove(key);
    }
    final session = ++_commentsSession;
    setState(() {
      _commentsKey = key;
      _comments = const [];
      _commentsLoading = true;
      _commentsError = '';
    });
    _diagComments('loading', platform: platform, videoId: videoId);
    _CommentPage page;
    try {
      page = await _loadCommentPage(
        key: key,
        platform: platform,
        videoId: videoId,
        source: force ? 'retry' : 'panel',
        force: force,
      );
    } catch (error) {
      page = _CommentPage(
        list: const <ShortVideoComment>[],
        error: 'network',
        detail: '$error',
        elapsedMs: 0,
        fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    if (!mounted || session != _commentsSession) return;
    _applyCommentPage(key, page);
    _diagCommentsForPage(page, platform: platform, videoId: videoId);
  }

  void _applyCommentPage(String key, _CommentPage page) {
    setState(() {
      _commentsKey = key;
      _commentsLoading = false;
      _comments = page.list;
      _commentsError = page.error;
    });
  }

  void _diagCommentsForPage(
    _CommentPage page, {
    required ShortVideoPlatform platform,
    required String videoId,
  }) {
    if (page.list.isNotEmpty) {
      _diagComments(
        'success',
        platform: platform,
        videoId: videoId,
        count: page.list.length,
      );
    } else if (page.error == 'empty') {
      _diagComments(
        'empty',
        platform: platform,
        videoId: videoId,
        reason: page.error,
      );
    } else {
      _diagComments(
        'error',
        platform: platform,
        videoId: videoId,
        reason: page.error.isEmpty ? 'blocked' : page.error,
        detail: page.detail,
      );
    }
  }

  /// 按 `platform:videoId` 合并请求。预取与面板打开共享同一个 Future，
  /// 避免同一视频同时开两个离屏网页。
  Future<_CommentPage> _loadCommentPage({
    required String key,
    required ShortVideoPlatform platform,
    required String videoId,
    required String source,
    bool force = false,
  }) {
    if (force) {
      _commentRequests.remove(key);
      _commentCache.remove(key);
    } else {
      final pending = _commentRequests[key];
      if (pending != null) {
        DiagProbe.event('comments-prefetch', <String, Object?>{
          'key': key,
          'hit': false,
          'elapsedMs': 0,
          'count': null,
          'state': 'join',
          'source': source,
        });
        return pending;
      }
    }
    final stopwatch = Stopwatch()..start();
    DiagProbe.event('comments-prefetch', <String, Object?>{
      'key': key,
      'hit': false,
      'elapsedMs': 0,
      'count': null,
      'state': 'start',
      'source': source,
      'limit': _commentsFirstPageLimit,
    });
    late final Future<_CommentPage> tracked;
    tracked = _fetchCommentPage(
      platform: platform,
      videoId: videoId,
      force: force,
      stopwatch: stopwatch,
    ).then((page) {
      if (identical(_commentRequests[key], tracked)) {
        if (page.list.isNotEmpty || page.error == 'empty') {
          _commentCache[key] = page;
          _trimCommentCache();
        }
      }
      DiagProbe.event('comments-prefetch', <String, Object?>{
        'key': key,
        'hit': false,
        'elapsedMs': page.elapsedMs,
        'count': page.list.length,
        'state': page.list.isNotEmpty ? 'done' : 'failed',
        'source': source,
        if (page.error.isNotEmpty) 'reason': page.error,
      });
      return page;
    }).whenComplete(() {
      if (identical(_commentRequests[key], tracked)) {
        _commentRequests.remove(key);
      }
    });
    _commentRequests[key] = tracked;
    return tracked;
  }

  Future<_CommentPage> _fetchCommentPage({
    required ShortVideoPlatform platform,
    required String videoId,
    required bool force,
    required Stopwatch stopwatch,
  }) async {
    var list = const <ShortVideoComment>[];
    var reason = '';
    var detail = '';
    try {
      list = await ShortVideoWeb.resolveComments(
        platformId: platform.id,
        videoId: videoId,
        userAgent: platform.userAgent,
        limit: _commentsFirstPageLimit,
        force: force,
      );
      if (list.isEmpty) {
        reason = ShortVideoWeb.lastCommentError.isEmpty
            ? 'blocked'
            : ShortVideoWeb.lastCommentError;
      }
    } catch (error) {
      // 通道异常 / 超时也必须落到失败态：_commentsLoading 一旦留成 true，
      // 面板就停在骨架屏上，看起来和「没打开」一样。
      reason = 'network';
      detail = '$error';
    }
    stopwatch.stop();
    return _CommentPage(
      list: list,
      error: reason,
      detail: detail,
      elapsedMs: stopwatch.elapsedMilliseconds,
      fetchedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _trimCommentCache() {
    while (_commentCache.length > _maxCommentCacheEntries) {
      _commentCache.remove(_commentCache.keys.first);
    }
  }

  /// 评论面板的取证事件：opened / loading / success / empty / error。
  ///
  /// 评论要等原生开网页抓接口，真机上「打不开」既可能是面板没弹出来，
  /// 也可能是还在加载或拿不到数据。把打开结果、平台、视频 id 和失败原因
  /// 都写进同一条日志，现场只看 `comments-panel` 就能区分。
  void _diagComments(
    String state, {
    required ShortVideoPlatform platform,
    required String videoId,
    String reason = '',
    int? count,
    String detail = '',
  }) {
    final fields = <String, Object?>{
      'state': state,
      'platform': platform.id,
      'videoId': videoId,
      if (reason.isNotEmpty) 'reason': reason,
    };
    if (count != null) fields['count'] = count;
    if (detail.isNotEmpty) {
      fields['detail'] = detail.length > 160
          ? detail.substring(0, 160)
          : detail;
    }
    try {
      DiagProbe.event('comments-panel', fields);
    } catch (_) {
      // 取证是旁路：写日志失败也不能挡住面板打开或评论状态落位。
    }
  }

  /// 页内面板：半透明遮罩 + 底部卡片。
  ///
  /// 不用 `showModalBottomSheet`：这条页面是 `Get.to` 推进来的，弹层路由
  /// 在 iOS 真机上不可见，评论/画质/更多三个入口全部表现为「按不动」。
  /// 放进同一个 Stack 后，面板和控件同一条合成链，点击必定有反馈。
  Widget _panelOverlay() {
    final panel = _panel;
    if (panel == null) return const SizedBox.shrink();
    final Widget body = switch (panel) {
      _PlayerPanel.comments => _commentsPanelBody(),
      _PlayerPanel.more => _morePanelBody(),
      _PlayerPanel.quality => _qualityPanelBody(),
      _PlayerPanel.audioQuality => _audioQualityPanelBody(),
      _PlayerPanel.decode => _decodePanelBody(),
      _PlayerPanel.subtitle => _subtitlePanelBody(),
      _PlayerPanel.rotateFlip => _rotateFlipPanelBody(),
      _PlayerPanel.title => _titlePanelBody(),
      _PlayerPanel.playMode => _playModePanelBody(),
    };
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closePanel,
              child: const ColoredBox(color: Color(0x99000000)),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.7,
              ),
              child: Material(
                color: const Color(0xFF1A1A1A),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: SafeArea(top: false, child: body),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 评论面板：打开时回视频页抓评论，加载中给骨架，失败给网页入口。
  Widget _commentsPanelBody() {
    final entry = _current;
    final video = entry.short;
    final platform =
        ShortVideoPlatform.fromId(video?.platform) ?? ShortVideoPlatform.douyin;
    final videoId = video?.videoId ?? '';
    final bvid = entry.bvid ?? '';
    final shareUrl = bvid.isNotEmpty
        ? 'https://www.bilibili.com/video/$bvid'
        : (videoId.isEmpty ? '' : platform.shareUrl(videoId));
    final header = _comments.isNotEmpty ? '评论 · ${_comments.length}' : '评论';
    final double targetHeight = MediaQuery.sizeOf(context).height * 0.62;
    // 外层最多给 70% 屏高，SafeArea 还要再扣底部安全区。矮屏 / 横屏下
    // 固定 62% 会顶破约束，这里按实际可用高度收一刀，保证面板永远有地方放。
    return LayoutBuilder(
      builder: (context, constraints) {
        final double height =
            constraints.maxHeight.isFinite &&
                constraints.maxHeight < targetHeight
            ? constraints.maxHeight
            : targetHeight;
        return SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              children: [
                _sheetHeader(header),
                _commentCaption(entry.title),
                const SizedBox(height: 8),
                Expanded(
                  child: _commentsBody(platform: platform, shareUrl: shareUrl),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 视频文案放在评论列表上方，明确标注，可点击折叠。
  Widget _commentCaption(String title) {
    final text = title.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Material(
      color: const Color(0xFF232323),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () =>
            setState(() => _commentCaptionExpanded = !_commentCaptionExpanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0x332F9BFF),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '视频文案',
                  style: TextStyle(
                    color: Color(0xFF7FC4FF),
                    fontSize: 9,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  maxLines: _commentCaptionExpanded ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  _commentCaptionExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 16,
                  color: Colors.white38,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _commentsBody({
    required ShortVideoPlatform platform,
    required String shareUrl,
  }) {
    if (_commentsLoading) return _commentsLoadingBody();
    if (_comments.isNotEmpty) {
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: _comments.length,
        separatorBuilder: (context, index) => const Divider(
          height: 1,
          thickness: 0.5,
          color: Color(0x14FFFFFF),
        ),
        itemBuilder: (context, index) => _commentTile(_comments[index]),
      );
    }
    return _commentsStatusBody(platform: platform, shareUrl: shareUrl);
  }

  Widget _commentsStatusBody({
    required ShortVideoPlatform platform,
    required String shareUrl,
  }) {
    final reason = _commentsError;
    final login = reason == 'login';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _commentsStatusIcon(reason),
              size: 32,
              color: login ? const Color(0xFF7FC4FF) : Colors.white24,
            ),
            const SizedBox(height: 8),
            Text(
              _commentsEmptyTitle(),
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                _commentsHint(platform.album),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ),
            if (reason.isNotEmpty && reason != 'empty') ...[
              const SizedBox(height: 6),
              Text(
                '原因：${_commentsReasonLabel(reason)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white30,
                  fontSize: 10,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (login) ...[
              FilledButton.icon(
                onPressed: () => unawaited(_openLoginWeb(platform)),
                icon: const Icon(Icons.login, size: 16),
                label: Text('打开网页登录${platform.album}'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2F9BFF),
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (shareUrl.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => unawaited(_openCommentPage(shareUrl)),
                icon: const Icon(Icons.open_in_browser, size: 16),
                label: Text(login ? '在浏览器打开视频页' : '在浏览器中打开该视频'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Color(0x33FFFFFF)),
                ),
              ),
            if (reason != 'unsupported')
              TextButton(
                onPressed: () => unawaited(_ensureComments(force: true)),
                child: const Text('重新加载'),
              ),
          ],
        ),
      ),
    );
  }

  IconData _commentsStatusIcon(String reason) {
    return switch (reason) {
      'login' => Icons.lock_outline,
      'blocked' => Icons.shield_outlined,
      'network' => Icons.wifi_off,
      'unsupported' => Icons.block,
      _ => Icons.chat_bubble_outline,
    };
  }

  Widget _commentsLoadingBody() {
    return Column(
      children: [
        const LinearProgressIndicator(
          minHeight: 2,
          color: Colors.lightBlueAccent,
          backgroundColor: Color(0x22FFFFFF),
        ),
        const SizedBox(height: 8),
        const Text(
          '正在从视频页读取评论，通常需要 5–20 秒…',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 6,
            itemBuilder: (context, index) => const _CommentSkeletonTile(),
          ),
        ),
      ],
    );
  }

  Widget _commentTile(ShortVideoComment comment) {
    final time = _commentTimeText(comment.time);
    final likes = _likeText(comment.likes);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _commentAvatar(comment),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.authorText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                        ),
                      ),
                    ),
                    if (time.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        time,
                        style: const TextStyle(
                          color: Colors.white30,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  comment.text,
                  style: const TextStyle(
                    color: Color(0xFFE6E6E6),
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          if (likes.isNotEmpty) ...[
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Column(
                children: [
                  const Icon(
                    Icons.favorite_border,
                    size: 13,
                    color: Colors.white38,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    likes,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _commentAvatar(ShortVideoComment comment) {
    final fallback = CircleAvatar(
      radius: 16,
      backgroundColor: const Color(0xFF2F2F2F),
      child: Text(
        _avatarText(comment.authorText),
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
    final uri = Uri.tryParse(comment.avatar);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return fallback;
    }
    return ClipOval(
      child: Image.network(
        uri.toString(),
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => fallback,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: 32,
            height: 32,
            color: const Color(0xFF2A2A2A),
          );
        },
      ),
    );
  }

  String _avatarText(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return String.fromCharCode(trimmed.runes.first);
  }

  String _commentTimeText(int seconds) {
    if (seconds <= 0) return '';
    final at = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    final month = at.month.toString().padLeft(2, '0');
    final day = at.day.toString().padLeft(2, '0');
    return '${at.year}-$month-$day';
  }

  String _likeText(int likes) {
    if (likes <= 0) return '';
    if (likes >= 10000) {
      return '${(likes / 10000).toStringAsFixed(1)}万';
    }
    return '$likes';
  }

  String _commentsEmptyTitle() {
    return switch (_commentsError) {
      'unsupported' => '无法读取评论',
      'login' => '需要先登录',
      'blocked' => '评论被平台拦截',
      'network' => '评论加载失败',
      'empty' => '暂无评论',
      _ => '暂无评论',
    };
  }

  String _commentsReasonLabel(String reason) {
    return switch (reason) {
      'login' => '登录态缺失',
      'blocked' => '平台未返回评论（风控或接口无响应）',
      'network' => '网络或视频页加载失败',
      'unsupported' => '当前视频没有可用的评论页',
      'empty' => '没有评论',
      _ => '未知原因',
    };
  }

  String _commentsHint(String album) {
    return switch (_commentsError) {
      'login' => '先打开网页登录$album，登录后再点「重新加载」。',
      'blocked' => '评论接口没有返回数据，可能触发了平台风控；可以稍后重试，或直接去网页里看。',
      'network' => '网络不稳定，或视频页没能打开，请检查网络后重试。',
      'unsupported' => '当前只抓抖音 / TikTok 的评论，可先去网页查看。',
      'empty' => '这条视频还没有人评论，去抢个沙发吧。',
      _ => '平台没有公开评论，或这条视频还没有人评论。',
    };
  }

  /// 「去登录」必须打开 App 内的网页：评论抓取读的是原生 WKWebView 那罐
  /// cookie，外部浏览器登录不会回传。登录完成回到播放页，再点「重新加载」。
  Future<void> _openLoginWeb(ShortVideoPlatform platform) async {
    final videoId = _current.short?.videoId ?? '';
    _diagComments('login-open', platform: platform, videoId: videoId);
    try {
      await ShortVideoWeb.open(platform);
    } catch (error) {
      _diagComments(
        'login-error',
        platform: platform,
        videoId: videoId,
        reason: 'open-failed',
        detail: '$error',
      );
      if (mounted) SmartDialog.showToast('无法打开登录页，请改用浏览器');
    }
  }

  Future<void> _openCommentPage(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) SmartDialog.showToast('无法打开浏览器');
    } catch (_) {
      SmartDialog.showToast('无法打开浏览器');
    }
  }

  /// 播放模式：六项平铺，当前项高亮，点选即生效并收起。
  Widget _playModePanelBody() {
    final options = <PlayRepeat?>[...PlayRepeat.values, null];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('播放模式'),
          for (final repeat in options)
            _playModeTile(
              repeat: repeat,
              selected: repeat == null
                  ? _shuffle
                  : !_shuffle && repeat == _repeat,
              onTap: () => _selectPlayMode(repeat),
            ),
        ],
      ),
    );
  }

  Widget _playModeTile({
    required PlayRepeat? repeat,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Icon(
        repeat == null ? Icons.shuffle : _playModeIconFor(repeat),
        size: 20,
        color: selected ? Colors.lightBlueAccent : Colors.white70,
      ),
      title: Text(
        repeat?.label ?? '随机播放',
        style: TextStyle(
          color: selected ? Colors.lightBlueAccent : Colors.white,
          fontSize: 14,
          fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
        ),
      ),
      trailing: selected
          ? const Icon(Icons.check, size: 18, color: Colors.lightBlueAccent)
          : null,
    );
  }

  /// 画质：接口没有档位，只显示打开面板时读到的实际分辨率。
  ///
  /// 不伪造「默认/高清/超清」这类档位：收藏接口只返回一条播放地址，
  /// 点这些假档位不会改变任何东西，正是用户反馈里最像「假按钮」的东西。
  Widget _qualityPanelBody() {
    final resolution = _qualityWidth != null && _qualityHeight != null
        ? '$_qualityWidth × $_qualityHeight'
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('画质'),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.check,
              size: 20,
              color: Colors.lightBlueAccent,
            ),
            title: Text(
              resolution == null ? '当前分辨率未读到' : '当前 $resolution',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: const Text(
              '收藏接口只返回一条播放地址，没有分辨率档位可切；'
              '这里显示的是最近一次采样到的实际分辨率。',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 音质：单条 mp4 只有一条内嵌音轨，不提供音质档位。
  Widget _audioQualityPanelBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('音质'),
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.graphic_eq,
              size: 20,
              color: Colors.lightBlueAccent,
            ),
            title: Text(
              '源音轨',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: Text(
              '收藏接口返回的是单条 mp4，只有一条内嵌音轨，'
              '没有可切换的音质档位，按源音量播放。',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 解码：只展示请求值和播放器实际上报的当前解码器，不改 hwdec 取值。
  Widget _decodePanelBody() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('解码'),
          _sheetTile(
            icon: Icons.settings_suggest_outlined,
            title: '请求解码器',
            subtitle: _queue.isEmpty ? _hwdec : _effectiveHwdecFor(_current.key),
          ),
          _sheetTile(
            icon: Icons.memory_outlined,
            title: '当前解码器',
            subtitle: _decodeCurrent.isEmpty
                ? '未读到（还没有采到当前流的解码器）'
                : _decodeCurrent,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              '解码方式由播放器按机型能力自动选择，这里只做展示。',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  /// 字幕：该来源没有字幕数据，不伪造档位，也不给会报错的开关。
  Widget _subtitlePanelBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('字幕'),
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.closed_caption_off_outlined,
              size: 20,
              color: Colors.white70,
            ),
            title: Text(
              '无字幕轨道',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: Text(
              '该来源只提供单条视频流，接口没有返回字幕数据，'
              '因此没有可切换的字幕档位。',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 旋转翻转：旋转渲染层 + 左右/上下镜像，和 B 站播放页的翻转入口一致。
  Widget _rotateFlipPanelBody() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('旋转翻转'),
          _sheetTile(
            icon: Icons.rotate_90_degrees_cw,
            title: '顺时针旋转',
            subtitle: '当前 ${_quarterTurns * 90}°',
            onTap: _rotateVideo,
          ),
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            secondary: const Icon(
              Icons.flip,
              size: 20,
              color: Colors.white70,
            ),
            title: const Text(
              '左右翻转',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            value: _player.flipX.value,
            activeThumbColor: Colors.lightBlueAccent,
            onChanged: (value) {
              _player.flipX.value = value;
              setState(() {});
            },
          ),
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            secondary: const Icon(
              Icons.flip,
              size: 20,
              color: Colors.white70,
            ),
            title: const Text(
              '上下翻转',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            value: _player.flipY.value,
            activeThumbColor: Colors.lightBlueAccent,
            onChanged: (value) {
              _player.flipY.value = value;
              setState(() {});
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 更多设置面板。
  ///
  /// 倍速和音量入口已按用户要求移除：音量用视频区上下滑动调节，
  /// 倍速不再在播放页暴露。顶栏放不下的动作（画质/音质/解码/字幕等）
  /// 收在这里，和顶栏图标走同一个动作入口。
  Widget _morePanelBody() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('更多设置'),
          // 顶栏放不下的动作按同一优先级收在这里，不另起一套入口。
          for (final action in _overflowActions(
            MediaQuery.sizeOf(context).width,
          ))
            _actionSheetTile(action),
          _sheetTile(
            icon: Icons.flip,
            title: '镜像翻转',
            subtitle: '左右 / 上下 · 长按旋转键也可进入',
            onTap: () => _openPanel(_PlayerPanel.rotateFlip),
          ),
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            secondary: const Icon(
              Icons.aspect_ratio,
              size: 20,
              color: Colors.white70,
            ),
            title: const Text(
              '画面填充',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: Text(
              _fillScreen
                  ? '裁剪铺满 · 竖屏铺满屏幕，横屏保持完整'
                  : '适应 · 保留完整画面，可能留黑边',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            value: _fillScreen,
            activeThumbColor: Colors.lightBlueAccent,
            onChanged: (value) {
              setState(() => _fillScreen = value);
              unawaited(_persistVideoFit());
            },
          ),
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            secondary: const Icon(
              Icons.picture_in_picture_alt_outlined,
              size: 20,
              color: Colors.white70,
            ),
            title: const Text(
              '诊断：PiP 轻量模式',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: const Text(
              '按窗口分辨率渲染并跳过 RotatedBox',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
            value: _pipLite,
            activeThumbColor: Colors.lightBlueAccent,
            onChanged: (value) {
              setState(() => _pipLite = value);
              unawaited(DiagProbe.setPipLiteMode(value));
              unawaited(_pushPipLiteMode(value));
            },
          ),
          if (kDiagEnabled)
            _sheetTile(
              icon: Icons.ios_share,
              title: '导出诊断',
              subtitle: 'pip_trace / 播放采样 / rootscan',
              onTap: () {
                _closePanel();
                unawaited(_exportDiagnostics());
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 完整文案面板：顶部标题只显示一行，长标题点开这里看全文。
  Widget _titlePanelBody() {
    final entry = _current;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('完整文案'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  entry.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '作者：${entry.author}',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _SwipeTarget { brightness, volume }

/// 播放页动作项。顺序即窄屏优先级：越靠前越先留在顶栏，其余收进「更多」。
///
/// 只包含 105 版那套控件，不提供倍速、音量、默认按钮——音量/亮度用
/// 上下滑，进度用左右滑。
enum _PlayerAction {
  comments,
  pip,
  quality,
  playMode,
  subtitle,
  rotate,
  audioOnly,
  cast,
  audioQuality,
  decode,
  playlist,
}

/// 播放页控件的宽度断点。
///
/// 只缩放命中区和间距，图标固定 20px：6S(375) 紧凑，15PM(430) 舒展，
/// 平板/横屏(>500) 再放大一档。
class _PlayerUiMetrics {
  const _PlayerUiMetrics({
    required this.hit,
    required this.gap,
    required this.edge,
    required this.topBarHeight,
    required this.bottomBarHeight,
    required this.inlineCap,
  });

  final double hit;
  final double gap;
  final double edge;
  final double topBarHeight;
  final double bottomBarHeight;

  /// 顶栏最多内联几个动作，剩下的进「更多」，不让图标铺满整行。
  final int inlineCap;

  static const double icon = 20;

  static const _PlayerUiMetrics _compact = _PlayerUiMetrics(
    hit: 32,
    gap: 10,
    edge: 12,
    topBarHeight: 48,
    bottomBarHeight: 52,
    inlineCap: 3,
  );

  static const _PlayerUiMetrics _regular = _PlayerUiMetrics(
    hit: 36,
    gap: 16,
    edge: 16,
    topBarHeight: 52,
    bottomBarHeight: 56,
    inlineCap: 5,
  );

  static const _PlayerUiMetrics _wide = _PlayerUiMetrics(
    hit: 40,
    gap: 16,
    edge: 16,
    topBarHeight: 56,
    bottomBarHeight: 60,
    inlineCap: 7,
  );

  static _PlayerUiMetrics ofWidth(double width) {
    if (width < 400) return _compact;
    if (width <= 500) return _regular;
    return _wide;
  }
}

/// 播放页内嵌面板的类型。
enum _PlayerPanel {
  comments,
  more,
  quality,
  audioQuality,
  decode,
  subtitle,
  rotateFlip,
  title,
  playMode,
}

/// 一次评论抓取的结果。缓存与面板共用同一份，避免两边对「空/失败」
/// 的判断不一致。
class _CommentPage {
  const _CommentPage({
    required this.list,
    required this.error,
    required this.elapsedMs,
    required this.fetchedAtMs,
    this.detail = '',
  });

  final List<ShortVideoComment> list;
  final String error;
  final String detail;
  final int elapsedMs;
  final int fetchedAtMs;
}

/// 评论加载中的占位行，和真实评论保持同一套间距。
class _CommentSkeletonTile extends StatelessWidget {
  const _CommentSkeletonTile();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: const BoxDecoration(
              color: Color(0xFF2A2A2A),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _bar(width: 88, height: 9),
                const SizedBox(height: 8),
                _bar(height: 10),
                const SizedBox(height: 6),
                _bar(width: 160, height: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar({double? width, required double height}) {
    return Container(
      width: width ?? double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// 进度条与时间文本的局部状态。单位是秒，和 `PlPlayerController` 的
/// `position/duration/buffered` 保持一致。
class _PlaybackProgress {
  const _PlaybackProgress({
    this.position = 0,
    this.duration = 0,
    this.buffered = 0,
  });

  final int position;
  final int duration;
  final int buffered;

  @override
  bool operator ==(Object other) =>
      other is _PlaybackProgress &&
      other.position == position &&
      other.duration == duration &&
      other.buffered == buffered;

  @override
  int get hashCode => Object.hash(position, duration, buffered);
}

class _GestureHint {
  const _GestureHint({
    required this.icon,
    required this.title,
    required this.detail,
    this.progress,
  });

  final IconData icon;
  final String title;
  final String detail;
  final double? progress;
}

/// 听音频模式下的画面提示。
///
/// 单条 mp4 没有独立音轨，关掉视频轨后画面会停在最后一帧（或变黑），
/// 不给提示的话看起来像播放器坏了。这一层不接手势，滑动/双击仍然照常。
class _AudioOnlyBadge extends StatelessWidget {
  const _AudioOnlyBadge();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xB3000000),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.headphones, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text(
              '仅音频播放',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放页构建器注册。`startPipQaIfRequested` 之类的外部入口靠它拿到页面。
Widget buildShortVideoPlayerPageInternal(
  List<QueueEntry> queue,
  int index, {
  bool showImmediately = false,
}) => ShortVideoPlayerPage(
  queue: queue,
  index: index,
  showImmediately: showImmediately,
);

/// 供收藏页「播这一条」用。
Future<void> playShortVideo(
  List<ShortVideo> videos,
  int index,
) async {
  final queue = videos.map(QueueEntry.fromShortVideo).toList(growable: false);
  await openShortVideoQueue(queue, index, replaceCurrent: true);
}
