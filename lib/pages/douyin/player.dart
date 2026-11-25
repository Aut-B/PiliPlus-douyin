import 'dart:async';

import 'package:PiliPlus/common/widgets/player_bar.dart';
import 'package:PiliPlus/common/widgets/progress_bar/audio_video_progress_bar.dart';
import 'package:PiliPlus/models_new/video/video_detail/page.dart' show Part;
import 'package:PiliPlus/pages/douyin/diag_probe.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
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
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:PiliPlus/utils/storage.dart';
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
  int _watchdogStartedAtMs = 0;
  bool _watchdogGraceUsed = false;
  int _watchdogOpenBusyRetries = 0;
  int _openStartPositionMs = 0;
  bool _firstFrameSeen = false;
  bool _recovering = false;
  int _autoRecoverCount = 0;
  int _recoverStreak = 0;

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

  /// 自动连播每 N 条主动重建一次 player/texture。手动选播 = 完整重建
  /// 能恢复，说明重建有效；这里提前做，防止累积到黑屏才被动救。
  static const int _autoRebuildInterval = 20;

  /// App 是否在前台。后台时看门狗只记日志，不做重建（原生 PiP 由 C23 处理）。
  bool _appPaused = false;

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
    return switch (_repeat) {
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
    _pushProgress(force: true);
    // 诊断包常开：每秒把 mpv 指标写进 Documents/diag_playback.log。
    // 普通包头一行就会 return，不产生文件。
    DiagProbe.startSession();
    DiagProbe.startSampling();
    _startPipTicker();
    IOSPipHelper.onAutoEnter = _pipAutoEnterHandler;
    _scheduleChromeHide();
    unawaited(_primeBrightness());
    unawaited(_primeVolume());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_dumpViewHierarchy());
      unawaited(PiliRootScan.run());
      unawaited(_open(_index, source: 'initial'));
      unawaited(_restoreShuffle());
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
    _chromeTimer?.cancel();
    _commentsSession++;
    _firstFrameWatchdog?.cancel();
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
    _disarmPipAutoEnter('shutdown');
    if (identical(IOSPipHelper.onAutoEnter, _pipAutoEnterHandler)) {
      IOSPipHelper.onAutoEnter = null;
    }
    DiagProbe.stop();
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
    if (source != 'auto-recover') _recoverStreak = 0;
    _cancelFirstFrameWatchdog();
    _firstFrameSeen = false;
    _opening = true;
    _completionArmed = false;
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
    try {
      final entry = _queue[target];
      // 切条探针：旧 textureId 必须在 setDataSource 前取，否则拿到的已经
      // 是新纹理，无法判断「换了纹理但没画面」。
      final oldTextureId = _player.videoController?.id.value;
      DiagProbe.beginOpen(
        index: target,
        key: entry.key,
        oldTextureId: oldTextureId,
        source: source,
      );
      // 切条期间 mpv 正持有解码锁，后台采样再去同步读属性只会把主
      // isolate 一起堵住；采样在 open 收尾后恢复。
      DiagProbe.suspendSampling();
      DiagProbe.openPhase('resolve');
      setState(() {
        _index = target;
        _error = null;
        _resetComments();
      });
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
      final media = await _resolveMedia(entry);
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
        setState(() => _error = '解析不出播放地址');
        return;
      }
      // 自动连播会优先吃预取结果，手动选播通常重新解析；把来源与是否本地
      // 缓存写进日志，才能对比两条 open 路径拿到的媒体是否不同。
      DiagProbe.event('open-media', <String, Object?>{
        'source': source,
        'index': target,
        'key': entry.key,
        'local': media.isLocal,
        'host': Uri.tryParse(media.url)?.host,
      });
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
      _publishPipState();
      _armPipAutoEnter('open');
      _completionArmed = true;
      _armedSession = session;
      _armFirstFrameWatchdog(
        session: session,
        index: target,
        source: source,
      );
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
      if (mounted) setState(() {});
    } catch (error) {
      openError = '$error';
      if (mounted) setState(() => _error = '播放失败：$error');
    } finally {
      DiagProbe.endOpen(error: openError);
      DiagProbe.resumeSampling();
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
  /// 会做一次同步 FFI 读取，只允许在看门狗（低频）里调用，不能放进
  /// 每秒多次的 position 回调。
  bool _hasFirstFrameNow() {
    if (_player.dataStatus.value != DataStatus.loaded) return false;
    if (_player.positionInMilliseconds <= 0) return false;
    return (_mpvVideoWidth() ?? 0) > 0;
  }

  void _armFirstFrameWatchdog({
    required int session,
    required int index,
    required String source,
  }) {
    _cancelFirstFrameWatchdog();
    _watchdogSession = session;
    _watchdogIndex = index;
    _watchdogSource = source;
    _watchdogStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    _watchdogOpenBusyRetries = 0;
    _firstFrameWatchdog = Timer(
      const Duration(milliseconds: _firstFrameWatchdogMs),
      () => _onFirstFrameWatchdog(session),
    );
  }

  void _cancelFirstFrameWatchdog() {
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    _watchdogGraceUsed = false;
    _watchdogOpenBusyRetries = 0;
  }

  void _onFirstFrameWatchdog(int session) {
    _firstFrameWatchdog = null;
    if (_disposed || _leaving || session != _openSession) return;
    if (_firstFrameSeen) {
      _recoverStreak = 0;
      return;
    }
    if (_hasFirstFrameNow()) {
      _firstFrameSeen = true;
      _recoverStreak = 0;
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
    });
    unawaited(
      _recoverNoFirstFrame(
        sinceOpenMs: sinceOpenMs,
        source: _watchdogSource,
      ),
    );
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
    var disposeCalls = 0;
    try {
      _detachPlayerListeners();
      _lastPositionTickMs = 0;
      try {
        // 单例按引用计数管理：若别的页面还持有旧实例，第一次 dispose 只会
        // 减计数、不拆 texture，自愈就退化成「同一个实例再 open 一次」，
        // 黑屏救不回来。这里补调用到引用计数归零（_instance 置空为标志），
        // 最多 8 次，避免异常状态下无限拆。
        while (disposeCalls < 8 && PlPlayerController.instance != null) {
          _player.dispose();
          disposeCalls++;
        }
      } catch (_) {}
      if (!mounted || _disposed || _leaving) return false;
      final instanceCleared = PlPlayerController.instance == null;
      _player = PlPlayerController.getInstance();
      _attachPlayerListeners();
      _progress.value = const _PlaybackProgress();
      sw.stop();
      DiagProbe.event('auto-recover-rebuilt', <String, Object?>{
        'index': index,
        'reason': reason,
        'disposeMs': sw.elapsedMilliseconds,
        'disposeCalls': disposeCalls,
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
    await _rebuildPlayerInstance(
      index: nextIndex,
      reason: 'proactive-rebuild',
      openSource: 'auto',
      retry: attempt,
    );
    return true;
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
  Future<QueueMedia?> _resolveMedia(QueueEntry entry) async {
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

  /// 算下一条要预热谁的 key。顺序模式取队列下一条，随机模式取牌堆首项。
  String _prefetchTargetKey() {
    if (_queue.length <= 1) return '';
    final String? key = _shuffle
        ? (_deck.isNotEmpty
              ? _deck.first
              : _queue[(_index + 1) % _queue.length].key)
        : switch (_repeat) {
            PlayRepeat.pause => null,
            PlayRepeat.singleCycle => null,
            PlayRepeat.listOrder =>
              _index + 1 < _queue.length ? _queue[_index + 1].key : null,
            PlayRepeat.listCycle => _queue[(_index + 1) % _queue.length].key,
            PlayRepeat.autoPlayRelated =>
              _queue[(_index + 1) % _queue.length].key,
          };
    if (key == null) return '';
    return key == _current.key ? '' : key;
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
      await _next();
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
        await _next();
        return;
    }
  }

  Future<void> _restoreShuffle() async {
    final keys = _queue.map((e) => e.key).toList(growable: false);
    _deckSignature = ShortVideoShuffleStore.signatureOf(keys);
    final saved = await ShortVideoShuffleStore.load();
    if (!mounted || saved == null) return;
    if (saved.signature != _deckSignature) return;
    _played.addAll(saved.played.where(keys.contains));
  }

  /// 下一条。顺序模式就是下一条，随机模式从牌堆里取，保证一轮之内不重复。
  Future<void> _next({String source = 'auto'}) async {
    if (_queue.length <= 1) {
      _diagSwitchRequest(source, _index);
      _diagSwitchBlocked(source, 'single-item', targetIndex: _index);
      return;
    }
    if (!_shuffle) {
      final int? next = switch (_repeat) {
        PlayRepeat.pause => _index + 1 < _queue.length ? _index + 1 : null,
        PlayRepeat.listOrder => _index + 1 < _queue.length ? _index + 1 : null,
        PlayRepeat.singleCycle => (_index + 1) % _queue.length,
        PlayRepeat.listCycle => (_index + 1) % _queue.length,
        PlayRepeat.autoPlayRelated => (_index + 1) % _queue.length,
      };
      if (next == null) {
        _diagSwitchRequest(source, _index);
        _diagSwitchBlocked(source, 'end-of-queue', targetIndex: _index);
        return;
      }
      _diagSwitchRequest(source, next);
      if (source == 'auto' && await _maybeAutoRebuildBeforeNext(next)) return;
      await _open(next, source: source);
      return;
    }
    if (_deck.isEmpty) _refillDeck();
    while (_deck.isNotEmpty) {
      final key = _deck.removeAt(0);
      if (key == _current.key) continue;
      final index = _queue.indexWhere((e) => e.key == key);
      if (index < 0) continue;
      _diagSwitchRequest(source, index);
      if (source == 'auto' && await _maybeAutoRebuildBeforeNext(index)) return;
      await _open(index, source: source);
      return;
    }
    final fallback = (_index + 1) % _queue.length;
    _diagSwitchRequest(source, fallback);
    if (source == 'auto' && await _maybeAutoRebuildBeforeNext(fallback)) return;
    await _open(fallback, source: source);
  }

  /// 重新发牌：这一轮没播过的都进去，洗一遍。
  void _refillDeck() {
    final remaining = _queue
        .map((e) => e.key)
        .where((key) => key != _current.key && !_played.contains(key))
        .toList();
    if (remaining.isEmpty) {
      // 一轮播完了：重开一轮，但把刚才那几条留在排除集里，
      // 避免新一轮第一首又正好是刚播过的。
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
        _recoverStreak = 0;
        unawaited(
          _recoverNoFirstFrame(sinceOpenMs: 0, source: 'playlist-select'),
        );
      }
      return;
    }
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
      );
    }
    _pushProgress(force: true);
    _publishPipState();
    if (_player.playerStatus.isPlaying) {
      _armPipAutoEnter('toggle-play');
    } else {
      _disarmPipAutoEnter('toggle-pause');
    }
  }

  Future<void> _enterPip() async {
    if (!IOSPipHelper.isAvailable) {
      SmartDialog.showToast('这台设备不支持画中画');
      return;
    }
    _pipEntered = true;
    // 手动按钮立即启动画中画并退后台，和 B 站播放页一致；autoEnter 只 arm
    // 不 start，用户点了按钮却留在前台会看起来什么都没发生。
    _player.enterPip(autoEnter: false);
    // 必须先 enter 再 update：PipSession 还不存在时 update 会被原生直接丢掉。
    unawaited(_pushPipLiteMode());
    // 显式带上 position：进入 PiP 必须强制下发一次，不能命中「状态未变」跳过。
    _publishPipState(_player.positionInMilliseconds);
  }

  /// 播放中武装自动画中画：原生置
  /// `canStartPictureInPictureAutomaticallyFromInline = true`，按 Home 退后台即起小窗。
  void _armPipAutoEnter(String reason) {
    if (_disposed || _leaving || !mounted || _appPaused) return;
    if (_pipAutoArmed || !IOSPipHelper.isAvailable) return;
    final textureId = _player.videoController?.id.value;
    if (textureId == null) return;
    _pipAutoArmed = true;
    _pipStartRequested = false;
    _player.enterPip(autoEnter: true);
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
    if (!_pipAutoArmed) return;
    _pipAutoArmed = false;
    _pipStartRequested = false;
    IOSPipHelper.disableAutoEnter();
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
    if (IOSPipHelper.isActive || !IOSPipHelper.isAvailable) return;
    if (!_player.playerStatus.isPlaying) return;
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
  void _startPipTicker() {
    _pipTicker ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
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
    DiagProbe.event('bg-keepalive', <String, Object?>{
      'enabled': handler.enableBackgroundPlay,
      'hasMediaItem': handler.mediaItem.value != null,
      'textureId': _player.videoController?.id.value,
      'entryKey': entry.key,
    });
  }

  void _releaseBackgroundKeepAlive() {
    final handler = videoPlayerServiceHandler;
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
  }

  /// 循环切换播放模式：顺序 → 列表循环 → 单个循环 → 播完暂停 →
  /// 自动连播 → 随机 → 回到顺序。随机也占一个状态，所以按钮永远只显示
  /// 当前那一种模式，不需要再单独放一个随机开关。
  void _cyclePlayMode() {
    _prefetchKey = null;
    _prefetchFuture = null;
    setState(() {
      if (_shuffle) {
        _shuffle = false;
        _repeat = PlayRepeat.listOrder;
      } else if (_repeat == PlayRepeat.listOrder) {
        _repeat = PlayRepeat.listCycle;
      } else if (_repeat == PlayRepeat.listCycle) {
        _repeat = PlayRepeat.singleCycle;
      } else if (_repeat == PlayRepeat.singleCycle) {
        _repeat = PlayRepeat.pause;
      } else if (_repeat == PlayRepeat.pause) {
        _repeat = PlayRepeat.autoPlayRelated;
      } else {
        _shuffle = true;
        _repeat = PlayRepeat.listCycle;
        _deck.clear();
        _refillDeck();
      }
    });
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
    final topInset = _chromeVisible ? viewPadding.top + _topBarHeight : 0.0;
    final bottomInset = _chromeVisible
        ? viewPadding.bottom + _bottomBarHeight
        : 0.0;
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
            // 视频只占中间那块。上下各留出一条，放控件，控件区和视频
            // 手势区在几何上不重叠，手指落在按钮上永远不会被视频层截走。
            //
            // 沉浸式（_chromeVisible 为 false）时上下两条都归零，视频铺满
            // 整个屏幕，和 B 站点一下画面进入沉浸式是同一个效果。
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
                child: _video(),
              ),
            ),
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
                height: viewPadding.top + _topBarHeight,
                child: _chromeBackdrop(
                  child: SafeArea(
                    top: true,
                    bottom: false,
                    left: false,
                    right: false,
                    minimum: EdgeInsets.zero,
                    child: _topBar(entry),
                  ),
                ),
              ),
            if (_chromeVisible)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: viewPadding.bottom + _bottomBarHeight,
                child: _chromeBackdrop(
                  bottom: true,
                  child: SafeArea(
                    top: false,
                    bottom: true,
                    left: false,
                    right: false,
                    minimum: EdgeInsets.zero,
                    child: _bottomBar(),
                  ),
                ),
              ),
            if (_panel != null) _panelOverlay(),
          ],
        ),
      ),
    );
  }

  /// 控件条底色。
  ///
  /// 以前控件条直接压在白底视频上：6S 是 375pt 宽，右上一个「更多设置」
  /// 图标本来就小，白色图标落在浅色画面上等于看不见，用户会当成「按了没用」。
  /// 现在上下各加一层很薄的黑色渐变，只做可读性，不做满屏蒙版。
  Widget _chromeBackdrop({required Widget child, bool bottom = false}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: bottom ? Alignment.bottomCenter : Alignment.topCenter,
          end: bottom ? Alignment.topCenter : Alignment.bottomCenter,
          colors: const [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: child,
    );
  }

  /// 顶部控件条高度；视频区域按这个留白，保证控件不被视频手势层覆盖。
  static const double _topBarHeight = 56;

  /// 底部控件条高度：进度行（时间 + 4px 轨道）+ 一排 34pt 按钮。15PM 的
  /// 底部安全区会再吃掉 34pt，这里留出余量，避免新布局在小屏上溢出。
  static const double _bottomBarHeight = 104;

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
    // 拖动本身不 seek，但松手后马上会 seek；从拖动开始就暂停后台采样，
    // 避免采样在 seek 的锁竞争窗口里同步读 mpv 属性。
    DiagProbe.suspendSampling();
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
          .whenComplete(DiagProbe.resumeSampling),
    );
    _pushProgress(force: true);
    _publishPipState(_seekTargetMs);
    _hideHintSoon();
    sw.stop();
    _diagUiBlock('gesture', 'horizontal-end', sw, throttleMs: 1000);
  }

  void _onHorizontalDragCancel() {
    if (!_seekDragging) return;
    _seekDragging = false;
    DiagProbe.resumeSampling();
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
    final video = RepaintBoundary(
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
    );
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
          child: _pipLite && _quarterTurns == 0
              ? video
              : RotatedBox(quarterTurns: _quarterTurns, child: video),
        ),
      ),
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
            return SafeArea(
              minimum: EdgeInsets.only(
                top: topInset + _topBarHeight + 6,
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
  Widget _controls(Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: child,
    );
  }

  Widget _topBar(QueueEntry entry) {
    // 左右图标统一 36×36 命中区、22px 图标，视觉等距；标题包一层点击，
    // 打开页内「完整文案」，避免长标题被省略号吃掉后没法看全。
    const double buttonSize = 36;
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
                  size: 26,
                ),
                // 返回必须永远可用，不能等收尾完成才响应——收尾里如果等原生
                // 关小窗卡住，用户看到的就是「点了没反应」。_leave 是同步的，
                // 收尾在它内部以 unawaited 方式启动。
                onTap: _leave,
                tooltip: '返回',
                width: buttonSize,
                height: buttonSize,
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
              ComBtn(
                icon: const Icon(
                  Icons.queue_music,
                  color: Colors.white,
                  size: 22,
                ),
                onTap: () => unawaited(_openPlaylist()),
                tooltip: '播放列表',
                width: buttonSize,
                height: buttonSize,
              ),
              ComBtn(
                icon: Icon(_playModeIcon, color: _playModeColor, size: 22),
                onTap: _cyclePlayMode,
                tooltip: _playModeLabel,
                width: buttonSize,
                height: buttonSize,
              ),
              ComBtn(
                icon: const Icon(
                  Icons.picture_in_picture_alt,
                  color: Colors.white,
                  size: 22,
                ),
                onTap: () => unawaited(_enterPip()),
                tooltip: '画中画',
                width: buttonSize,
                height: buttonSize,
              ),
              ComBtn(
                icon: const Icon(
                  Icons.more_vert_outlined,
                  color: Colors.white,
                  size: 22,
                ),
                onTap: () => _openPanel(_PlayerPanel.more),
                tooltip: '更多设置',
                width: buttonSize,
                height: buttonSize,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    // playerStatus 是普通字段，不是 Rx；暂停/播放图标由 `_isPlaying` 单独
    // 驱动，只重建这一个按钮。进度/缓冲/时长由 `_progress` 驱动，只重建
    // 进度条和时间文本，不跟着 position 回调刷新整页。
    //
    // 布局分两行：
    // * 进度行：当前时间 + 加粗进度条（带拖动圆点）+ 总时长，三者同一行
    //   基线对齐，时间不会和进度条错位；
    // * 操作行：左侧「上一条 / 暂停 / 下一条」播放组，右侧「评论 / 画中画 /
    //   旋转 / 更多」工具组，中间留白把两组分开。
    return _controls(
      Column(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<_PlaybackProgress>(
            valueListenable: _progress,
            builder: (context, progress, _) {
              return Row(
                children: [
                  _timeText(progress.position, Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ProgressBar(
                      progress: progress.position,
                      buffered: progress.buffered,
                      total: progress.duration,
                      // 已播 / 缓冲 / 未播三段颜色拉开，4px 轨道在深色画面上
                      // 也能看清；拖动时手柄带一圈柔光。
                      baseBarColor: const Color(0x3DFFFFFF),
                      progressBarColor: Colors.white,
                      bufferedBarColor: const Color(0x8AFFFFFF),
                      thumbColor: Colors.white,
                      thumbGlowColor: const Color(0x33FFFFFF),
                      barHeight: 4,
                      thumbRadius: 6,
                      thumbGlowRadius: 14,
                      // RenderProgressBar 只有 onDragStart/onHover 非空时才参与
                      // 命中测试，否则整条进度条点不动。空回调只为了可拖。
                      onDragStart: (_) {},
                      onSeek: (milliseconds) {
                        _player.position.value = milliseconds ~/ 1000;
                        // seek 会短暂抢 mpv 解码锁，采样先让开，完成后再恢复。
                        DiagProbe.suspendSampling();
                        unawaited(
                          _player
                              .seekTo(Duration(milliseconds: milliseconds))
                              .whenComplete(DiagProbe.resumeSampling),
                        );
                        _pushProgress(force: true);
                        _publishPipState(milliseconds);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  _timeText(progress.duration, Colors.white70),
                ],
              );
            },
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              ComBtn(
                icon: const Icon(
                  Icons.skip_previous,
                  color: Colors.white,
                  size: 24,
                ),
                onTap: () => unawaited(_previous()),
                tooltip: '上一条',
                width: _bottomButtonSize,
                height: _bottomButtonSize,
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _isPlaying,
                builder: (context, playing, child) => ComBtn(
                  icon: Icon(
                    playing ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 26,
                  ),
                  onTap: () => unawaited(_togglePlay()),
                  tooltip: '暂停/继续',
                  width: _bottomButtonSize,
                  height: _bottomButtonSize,
                ),
              ),
              ComBtn(
                icon: const Icon(
                  Icons.skip_next,
                  color: Colors.white,
                  size: 24,
                ),
                onTap: () => unawaited(_next(source: 'next')),
                tooltip: '下一条',
                width: _bottomButtonSize,
                height: _bottomButtonSize,
              ),
              // 工具组在窄屏（6S/SE）上整体等比缩小，不换行、不溢出。
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ComBtn(
                          icon: const Icon(
                            Icons.chat_bubble_outline,
                            color: Colors.white,
                            size: 20,
                          ),
                          onTap: () => _openPanel(_PlayerPanel.comments),
                          tooltip: '评论',
                          width: _bottomButtonSize,
                          height: _bottomButtonSize,
                        ),
                        ComBtn(
                          icon: const Icon(
                            Icons.picture_in_picture_alt,
                            color: Colors.white,
                            size: 20,
                          ),
                          onTap: () => unawaited(_enterPip()),
                          tooltip: '画中画',
                          width: _bottomButtonSize,
                          height: _bottomButtonSize,
                        ),
                        ComBtn(
                          icon: const Icon(
                            Icons.screen_rotation_alt,
                            color: Colors.white,
                            size: 20,
                          ),
                          onTap: _rotateVideo,
                          tooltip: '画面旋转',
                          width: _bottomButtonSize,
                          height: _bottomButtonSize,
                        ),
                        ComBtn(
                          icon: const Icon(
                            Icons.more_vert_outlined,
                            color: Colors.white,
                            size: 20,
                          ),
                          onTap: () => _openPanel(_PlayerPanel.more),
                          tooltip: '更多设置',
                          width: _bottomButtonSize,
                          height: _bottomButtonSize,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 底部按钮统一命中区，图标大小在按钮内单独控制。
  static const double _bottomButtonSize = 34;

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

  /// 点击画面：切换沉浸式。
  ///
  /// 只挂在视频层的 onTap 上。视频层和控件条在几何上不重叠，所以点按钮
  /// 不会顺带把控件收起来（B 站播放页那套是整屏一层手势，这里刻意不这么写）。
  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    _scheduleChromeHide();
  }

  /// 控件显示后 4 秒自动收起。用户又点一下可以立刻再收。
  void _scheduleChromeHide() {
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
  void _openPanel(_PlayerPanel panel) {
    _chromeTimer?.cancel();
    setState(() => _panel = panel);
    if (panel == _PlayerPanel.comments) unawaited(_ensureComments());
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
  }

  /// 打开评论面板时抓一次评论。同一条视频的加载中/成功结果直接复用，
  /// 切条后 [_resetComments] 会把 key 清掉，旧请求的回包也会被 session 丢弃。
  Future<void> _ensureComments({bool force = false}) async {
    final entry = _current;
    final video = entry.short;
    final platform =
        ShortVideoPlatform.fromId(video?.platform) ?? ShortVideoPlatform.douyin;
    final videoId = video?.videoId ?? '';
    if (videoId.isEmpty) {
      setState(() {
        _commentsKey = '${platform.id}:';
        _comments = const [];
        _commentsLoading = false;
        _commentsError = 'unsupported';
      });
      return;
    }
    final key = '${platform.id}:$videoId';
    if (!force &&
        key == _commentsKey &&
        (_commentsLoading ||
            _comments.isNotEmpty ||
            _commentsError.isNotEmpty)) {
      return;
    }
    final session = ++_commentsSession;
    setState(() {
      _commentsKey = key;
      _comments = const [];
      _commentsLoading = true;
      _commentsError = '';
    });
    final list = await ShortVideoWeb.resolveComments(
      platformId: platform.id,
      videoId: videoId,
      userAgent: platform.userAgent,
      force: force,
    );
    if (!mounted || session != _commentsSession) return;
    setState(() {
      _commentsLoading = false;
      _comments = list;
      _commentsError = list.isEmpty
          ? (ShortVideoWeb.lastCommentError.isEmpty
                ? 'notfound'
                : ShortVideoWeb.lastCommentError)
          : '';
    });
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
      _PlayerPanel.title => _titlePanelBody(),
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
                  top: Radius.circular(14),
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
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.62,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          children: [
            _sheetHeader('评论'),
            const SizedBox(height: 4),
            Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _commentsBody(platform: platform, shareUrl: shareUrl),
            ),
          ],
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
          color: Color(0x1FFFFFFF),
        ),
        itemBuilder: (context, index) => _commentTile(_comments[index]),
      );
    }
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _commentsError == 'unsupported'
                  ? Icons.block
                  : Icons.chat_bubble_outline,
              size: 32,
              color: Colors.white24,
            ),
            const SizedBox(height: 8),
            Text(
              _commentsEmptyTitle(),
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              _commentsHint(platform.album),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            const SizedBox(height: 16),
            if (shareUrl.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => unawaited(_openCommentPage(shareUrl)),
                icon: const Icon(Icons.open_in_browser, size: 16),
                label: const Text('在浏览器中打开该视频'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Color(0x33FFFFFF)),
                ),
              ),
            if (_commentsError != 'unsupported')
              TextButton(
                onPressed: () => unawaited(_ensureComments(force: true)),
                child: const Text('重新加载'),
              ),
          ],
        ),
      ),
    );
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
          '正在从视频页读取评论…',
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
          CircleAvatar(
            radius: 15,
            backgroundColor: const Color(0xFF2A2A2A),
            child: Text(
              _avatarText(comment.authorText),
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        comment.authorText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (time.isNotEmpty)
                      Text(
                        time,
                        style: const TextStyle(
                          color: Colors.white30,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  comment.text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (likes.isNotEmpty) ...[
            const SizedBox(width: 8),
            Column(
              children: [
                const Icon(
                  Icons.favorite_border,
                  size: 14,
                  color: Colors.white38,
                ),
                const SizedBox(height: 2),
                Text(
                  likes,
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ],
            ),
          ],
        ],
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
    if (_commentsError == 'unsupported') return '无法读取评论';
    if (_commentsError == 'login' ||
        _commentsError == 'network' ||
        _commentsError == 'notfound') {
      return '评论加载失败';
    }
    return '该视频暂无评论';
  }

  String _commentsHint(String album) {
    return switch (_commentsError) {
      'login' => '需要先在网页抓取里登录$album，才能读到评论。',
      'network' => '网络不稳定，评论加载失败，可稍后重试。',
      'unsupported' => '当前只抓抖音 / TikTok 的评论，可先去网页查看。',
      'notfound' => '没等到评论接口，可能被平台风控拦截，可去网页里看。',
      _ => '平台没有公开评论，或这条视频还没有人评论。',
    };
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

  /// 画质：接口没有档位，只显示当前实际使用的「默认」，点开说明原因。
  Widget _qualityPanelBody() {
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
            title: const Text(
              '默认',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: const Text(
              '收藏接口只返回播放地址，不提供分辨率档位，'
              '当前按源地址的默认清晰度播放。',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 更多设置面板。
  ///
  /// 倍速和音量入口已按用户要求移除：音量用视频区上下滑动调节，
  /// 倍速不再在播放页暴露。画质项改为可点，打开同一套页内画质说明。
  Widget _morePanelBody() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('更多设置'),
          _sheetTile(
            icon: Icons.high_quality_outlined,
            title: '画质',
            subtitle: '默认 · 接口未提供分辨率',
            onTap: () => _openPanel(_PlayerPanel.quality),
          ),
          _sheetTile(
            icon: Icons.screen_rotation_alt,
            title: '画面旋转',
            subtitle: '${_quarterTurns * 90}°',
            onTap: _rotateVideo,
          ),
          _sheetTile(
            icon: _playModeIcon,
            title: '播放模式',
            subtitle: '$_playModeLabel · 点击切换',
            onTap: _cyclePlayMode,
          ),
          _sheetTile(
            icon: Icons.picture_in_picture_alt_outlined,
            title: '画中画',
            onTap: () {
              _closePanel();
              unawaited(_enterPip());
            },
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

/// 播放页内嵌面板的类型。
enum _PlayerPanel { comments, more, quality, title }

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
