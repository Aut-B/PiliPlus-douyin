import 'dart:async';

import 'package:PiliPlus/common/widgets/player_bar.dart';
import 'package:PiliPlus/common/widgets/progress_bar/audio_video_progress_bar.dart';
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
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

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

class _ShortVideoPlayerPageState extends State<ShortVideoPlayerPage> {
  late final List<QueueEntry> _queue = List<QueueEntry>.of(widget.queue);
  late int _index = widget.index.clamp(0, _queue.length - 1);

  final PlPlayerController _player = PlPlayerController.getInstance();

  /// 随机播放的牌堆。空表示需要重新发牌。
  final List<String> _deck = <String>[];
  String _deckSignature = '';

  bool _opening = false;

  /// 加载期间在播放列表里点下的目标条目；当前 [_open] 收尾后补跳。
  ///
  /// 不加这个字段的话，`_opening` 为真时那次点击会被直接丢掉：列表页
  /// 已经 pop 掉了，用户看到列表关闭、视频却没换。
  int? _pendingOpenIndex;
  String? _error;
  bool _shuffle = false;

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

  /// 页面已经在退，避免重复触发。
  bool _leaving = false;

  /// 当前这次横向拖动累计的位移（像素）。用来判断「滑得够不够远」，
  /// 不依赖瞬时速度——慢速拖动也应该能返回。
  double _dragDx = 0;

  /// 视频层竖向手势当前调的是亮度还是音量。null 表示没在竖向拖动。
  _SwipeTarget? _swipeTarget;
  double _swipeStartY = 0;
  double _swipeStartValue = 0;

  double _brightness = 1;
  double _volume = 1;
  bool _brightnessPrimed = false;
  bool _volumePrimed = false;

  /// 系统亮度不可写时退回应用亮度，退出播放页要把它复位。
  bool _brightnessIsApplication = false;

  /// 横向拖动的起点/预览目标，单位毫秒。
  int _seekStartMs = 0;
  int _seekTargetMs = 0;
  bool _seekDragging = false;

  /// 画面顺时针旋转的 90° 次数（0..3）。只旋转渲染层，不改原生屏幕方向。
  int _quarterTurns = 0;

  /// 亮度/音量/进度提示只重建这一小块，拖动时不用 setState 整页。
  final ValueNotifier<_GestureHint?> _gestureHint =
      ValueNotifier<_GestureHint?>(null);
  Timer? _gestureHintTimer;

  /// 画中画状态推送的节拍器。
  ///
  /// iOS 的 AVSampleBufferDisplayLayer 用 timebase 给每帧打 PTS，而原生
  /// timebase 只有收到带 position 的 update 才会推进。此前抖音页从不推送，
  /// timebase 停在 0，老机型会把后续帧当成重复帧，画中画卡在第一帧。
  Timer? _pipTicker;

  QueueEntry get _current => _queue[_index];

  @override
  void initState() {
    super.initState();
    _player.addStatusLister(_onPlayerStatus);
    _statusListening = true;
    _startPipTicker();
    unawaited(_primeBrightness());
    unawaited(_primeVolume());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_dumpViewHierarchy());
      unawaited(PiliRootScan.run());
      unawaited(_open(_index));
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

  @override
  void dispose() {
    _stopPipTicker();
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
    _stopPipTicker();
    if (_statusListening) {
      _statusListening = false;
      _player.removeStatusLister(_onPlayerStatus);
    }
    try {
      if (_pipEntered && IOSPipHelper.isActive) {
        IOSPipHelper.dispose();
        _pipEntered = false;
      }
    } catch (_) {}
    try {
      // 单例的 dispose 会把 _instance 置空，下次进播放页重新 getInstance 拿到
      // 干净实例。前提是本页只在 dispose() 时做，绝不在 build 期间调用。
      _player.dispose();
    } catch (_) {}
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
  Future<void> _open(int index) async {
    if (_opening || _queue.isEmpty) return;
    final target = index.clamp(0, _queue.length - 1);
    final session = ++_openSession;
    _opening = true;
    _completionArmed = false;
    try {
      final entry = _queue[target];
      setState(() {
        _index = target;
        _error = null;
      });
      // 抖音 / TikTok 的 CDN 按网页会话校验，必须带上 WKWebView 那罐 cookie，
      // 否则「地址解析出来了、一播就 403」。
      //
      // 但取 cookie 不能挡在开播前面：本地已经缓存好整条时，它是纯磁盘读取。
      // 之前无论本地有没有缓存，都先 await 一次 cookie（原生通道，网页没开过
      // 时是慢路径）再查缓存，串行下来就是「右下角都显示缓存 281MB 了，还要
      // 等很久」。现在先试离线，命中就直接开播，cookie 完全不碰。
      final video = entry.short;
      final media =
          await fastOfflineMedia(entry) ??
          await () async {
            final cookie = video == null
                ? ''
                : await ShortVideoWeb.cookieHeader(
                    (ShortVideoPlatform.fromId(video.platform) ??
                            ShortVideoPlatform.douyin)
                        .cookieDomainNeedle,
                  );
            if (!mounted) return null;
            return resolveQueueEntry(entry, cookie: cookie);
          }();
      if (!mounted) return;
      if (media == null || media.url.isEmpty) {
        setState(() => _error = '解析不出播放地址');
        return;
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
      if (!mounted || session != _openSession) return;
      // `setDataSource(autoplay: true)` 内部的自动播放走的是静态
      // `playIfExists()`，只有 B 站视频页 / 直播页注册了那个回调。
      // 抖音页没有注册，只加载不会真正播放，这里在确认数据源就绪后
      // 显式起播；首条和自动切出的下一条都会经过这里。
      if (_player.dataStatus.value != DataStatus.loaded) return;
      await _player.play();
      if (!mounted || session != _openSession) return;
      _publishPipState();
      _completionArmed = true;
      _armedSession = session;
      setState(() {});
      _notePlayed(entry.key);
    } catch (error) {
      if (mounted) setState(() => _error = '播放失败：$error');
    } finally {
      _opening = false;
      // 加载期间用户在播放列表里点过别的条目：现在补跳过去，否则那次
      // 点击会石沉大海（列表已经关了，屏幕上什么都没变）。
      final pending = _pendingOpenIndex;
      _pendingOpenIndex = null;
      if (pending != null && mounted && !_leaving && !_disposed) {
        unawaited(_open(pending));
      }
    }
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

  /// 复用 B 站播放页的完成监听：controller 把 mpv 的 completed 流转成
  /// [PlayerStatus.completed] 后回调到这里。
  ///
  /// 只有「上一条已经真正播起来」才允许自动下一条；主动切歌、解析失败、
  /// 退出页面都不算完成。上膛只发生在当前会话成功加载并起播之后，
  /// 迟到的 `playing` 不会再打开标记。
  void _onPlayerStatus(PlayerStatus status) {
    _publishPipState();
    if (status == PlayerStatus.completed) {
      if (!_completionArmed || _armedSession != _openSession) return;
      if (_player.dataStatus.value != DataStatus.loaded) return;
      _completionArmed = false;
      if (_opening || _leaving || _disposed || !mounted) return;
      unawaited(_next());
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
  Future<void> _next() async {
    if (_queue.length <= 1) return;
    if (!_shuffle) {
      final next = (_index + 1) % _queue.length;
      await _open(next);
      return;
    }
    if (_deck.isEmpty) _refillDeck();
    while (_deck.isNotEmpty) {
      final key = _deck.removeAt(0);
      if (key == _current.key) continue;
      final index = _queue.indexWhere((e) => e.key == key);
      if (index < 0) continue;
      await _open(index);
      return;
    }
    await _open((_index + 1) % _queue.length);
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
    if (_queue.length <= 1) return;
    await _open((_index - 1 + _queue.length) % _queue.length);
  }

  /// 打开播放列表。列表里调序会回调 [_applyPlaylistOrder]，
  /// 点条目会回调 [_playFromPlaylist]，两边保持同一份顺序。
  Future<void> _openPlaylist() async {
    await Get.to<void>(
      () => ShortVideoPlaylistPage(
        currentKey: _current.key,
        onReorder: _applyPlaylistOrder,
        onPlay: _playFromPlaylist,
      ),
    );
  }

  /// 播放列表调序后，把当前队列里同样存在的条目按新顺序重排。
  ///
  /// 队列和播放列表未必完全一样（收藏页直接开播时列表可能是空的），
  /// 所以只重排在两边的条目，其余条目留在原位，不改变队列长度。
  void _applyPlaylistOrder(List<PlaylistItem> items) {
    if (items.isEmpty || _queue.isEmpty) return;
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
    final target = index.clamp(0, entries.length - 1);
    final key = entries[target].key;
    final wasCurrentKey = _current.key;
    setState(() {
      _queue
        ..clear()
        ..addAll(entries);
      _index = target;
    });
    // 点的就是当前这条：只把队列换成列表顺序，不重新加载打断播放。
    if (key == wasCurrentKey) return;
    // 正在解析/加载上一条时不能直接丢弃这次点击：列表已经关了，用户点了却
    // 什么都没发生。记下来，等当前这次 _open 收尾时补跳。
    if (_opening) {
      _pendingOpenIndex = target;
      return;
    }
    unawaited(_open(target));
  }

  Future<void> _togglePlay() async {
    if (_player.playerStatus.isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    _publishPipState();
    if (mounted) setState(() {});
  }

  Future<void> _enterPip() async {
    if (!IOSPipHelper.isAvailable) {
      SmartDialog.showToast('这台设备不支持画中画');
      return;
    }
    _pipEntered = true;
    _player.enterPip(autoEnter: true);
    _publishPipState();
  }

  /// 启动画中画状态推送。播放中每 500ms 推一次 position，原生 timebase
  /// 才会前进；只在进入画中画时推一次的话，老机型依旧会卡帧。
  void _startPipTicker() {
    _pipTicker ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
      _publishPipState();
    });
  }

  void _stopPipTicker() {
    _pipTicker?.cancel();
    _pipTicker = null;
  }

  /// 字段形状与 pl_player 的 `_iosPipState()` 对齐；position/duration 用毫秒。
  void _publishPipState([int? positionMs]) {
    if (_disposed || !mounted || !IOSPipHelper.needsUpdate) return;
    IOSPipHelper.update(<String, Object>{
      'isPlaying': _player.playerStatus.isPlaying,
      'isBuffering': _player.isBuffering.value,
      'isLive': _player.isLive,
      'position': positionMs ?? _player.positionInMilliseconds,
      'duration': _player.durationInMilliseconds,
      'speed': _player.playbackSpeed,
    });
  }

  void _toggleShuffle() {
    setState(() {
      _shuffle = !_shuffle;
      if (_shuffle) {
        _deck.clear();
        _refillDeck();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final entry = _current;
    return PopScope(
      // 系统返回手势 / 安卓返回键也要走收尾。注意这里是同步触发，
      // 不阻塞 pop，避免手势退出时同样被原生回调拖住。
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_shutdown());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // 视频只占中间那块。上下各留出一条，放控件，控件区和视频
            // 手势区在几何上不重叠，手指落在按钮上永远不会被视频层截走。
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(
                  top: MediaQuery.viewPaddingOf(context).top + _topBarHeight,
                  bottom:
                      MediaQuery.viewPaddingOf(context).bottom +
                      _bottomBarHeight,
                ),
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
            //    重叠的话，手指压到它左半边就没有反应。
            Positioned(
              left: 0,
              top: MediaQuery.viewPaddingOf(context).top + _topBarHeight,
              bottom:
                  MediaQuery.viewPaddingOf(context).bottom + _bottomBarHeight,
              width: _edgeSwipeWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
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
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.viewPaddingOf(context).top + _topBarHeight,
              child: SafeArea(
                top: true,
                bottom: false,
                left: false,
                right: false,
                minimum: EdgeInsets.zero,
                child: _topBar(entry),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height:
                  MediaQuery.viewPaddingOf(context).bottom + _bottomBarHeight,
              child: SafeArea(
                top: false,
                bottom: true,
                left: false,
                right: false,
                minimum: EdgeInsets.zero,
                child: _bottomBar(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部控件条高度；视频区域按这个留白，保证控件不被视频手势层覆盖。
  static const double _topBarHeight = 56;

  /// 底部控件条高度：进度条 + 一排按钮。15PM 的底部安全区会再吃掉 34pt，
  /// 所以这里把进度条和按钮算进去后留出余量，避免 15PM 上溢出。
  static const double _bottomBarHeight = 96;

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
    final isLeft =
        details.localPosition.dx < MediaQuery.sizeOf(context).width / 2;
    _swipeTarget = isLeft ? _SwipeTarget.brightness : _SwipeTarget.volume;
    _swipeStartY = details.localPosition.dy;
    _swipeStartValue = isLeft ? _brightness : _volume;
    _publishSwipeHint(_swipeStartValue);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    final target = _swipeTarget;
    if (target == null) return;
    final isBrightness = target == _SwipeTarget.brightness;
    final range =
        MediaQuery.sizeOf(context).height * (isBrightness ? 0.6 : 0.5);
    final max = isBrightness ? 1.0 : _player.maxVolume;
    final value =
        (_swipeStartValue - (details.localPosition.dy - _swipeStartY) / range)
            .clamp(0.0, max)
            .toDouble();
    if (isBrightness) {
      unawaited(_applyBrightness(value));
    } else {
      _volume = value;
      unawaited(_player.setVolume(value, showIndicator: false));
    }
    _publishSwipeHint(value);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_swipeTarget == _SwipeTarget.brightness) {
      unawaited(_applyBrightness(_brightness));
    }
    _swipeTarget = null;
    _hideHintSoon();
  }

  void _onVerticalDragCancel() {
    _swipeTarget = null;
    _hideHintSoon();
  }

  /// 横向拖动只更新预览，松手才真正 seek，避免拖动途中反复冲缓冲。
  void _onHorizontalDragStart(DragStartDetails details) {
    final durationMs = _player.durationInMilliseconds;
    _seekDragging = durationMs > 0;
    if (!_seekDragging) return;
    var start = _player.positionInMilliseconds;
    if (start <= 0) start = _player.position.value * 1000;
    _seekStartMs = start.clamp(0, durationMs).toInt();
    _seekTargetMs = _seekStartMs;
    _showSeekHint();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_seekDragging) return;
    final durationMs = _player.durationInMilliseconds;
    final width = MediaQuery.sizeOf(context).width;
    if (durationMs <= 0 || width <= 0) return;
    final deltaMs = (details.delta.dx / width * durationMs).round();
    _seekTargetMs = (_seekTargetMs + deltaMs).clamp(0, durationMs).toInt();
    _showSeekHint();
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_seekDragging) return;
    _seekDragging = false;
    _player.position.value = _seekTargetMs ~/ 1000;
    unawaited(_player.seekTo(Duration(milliseconds: _seekTargetMs)));
    _publishPipState(_seekTargetMs);
    _hideHintSoon();
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
                onPressed: () => _open(_index),
                child: const Text('重试'),
              ),
              TextButton(onPressed: _next, child: const Text('下一条')),
            ],
          ),
        ),
      );
    }
    final controller = _player.videoController;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return GestureDetector(
      // 和 B站播放页一致：双击暂停/播放，单击不触发任何播放操作。
      //
      // 这里刻意只挂 onDoubleTap、不挂 onTap：两者同时存在时，单击要等约
      // 300ms 双击判定超时才会派发，控件层按钮的响应会跟着变慢。单击的
      // 事件照旧透传（translucent），也不吃掉外层横向滑返回的手势。
      //
      // 竖向/横向拖动和双击可以共存：点击不产生位移，拖动在手势仲裁里
      // 按主轴方向胜出，双击判定不会被抢走。左边缘那 20pt 的滑返回由
      // Stack 上层独立处理，命中测试到不了这里，所以横拖调进度不会误触退出。
      behavior: HitTestBehavior.translucent,
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
          child: RotatedBox(
            quarterTurns: _quarterTurns,
            child: RepaintBoundary(
              child: FittedBox(
                fit: BoxFit.contain,
                alignment: Alignment.center,
                child: SimpleVideo(
                  controller: controller,
                  fill: Colors.black,
                  aspectRatio: null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _gestureOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<_GestureHint?>(
          valueListenable: _gestureHint,
          builder: (context, hint, child) {
            if (hint == null) return const SizedBox.shrink();
            return Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  child: SizedBox(
                    width: 200,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(hint.icon, color: Colors.white, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              hint.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          hint.detail,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        if (hint.progress case final progress?) ...[
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 3,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation<Color>(
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
    return _controls(
      // 和 B站播放页一样用 PlayerBar：返回在左、标题居中、操作在右。
      // Center 负责在上下控件条里垂直居中；宽度约束仍然是撑满的。
      Center(
        child: PlayerBar(
          left: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ComBtn(
                icon: const Icon(
                  Icons.keyboard_arrow_down,
                  color: Colors.white,
                ),
                // 返回必须永远可用，不能等收尾完成才响应——收尾里如果等原生
                // 关小窗卡住，用户看到的就是「点了没反应」。_leave 是同步的，
                // 收尾在它内部以 unawaited 方式启动。
                onTap: _leave,
                tooltip: '返回',
              ),
            ],
          ),
          title: Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white),
          ),
          right: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ComBtn(
                icon: const Icon(Icons.queue_music, color: Colors.white),
                onTap: () => unawaited(_openPlaylist()),
                tooltip: '播放列表',
              ),
              ComBtn(
                icon: Icon(
                  _shuffle ? Icons.shuffle : Icons.swap_vert,
                  color: _shuffle ? Colors.lightBlueAccent : Colors.white,
                ),
                onTap: _toggleShuffle,
                tooltip: _shuffle ? '随机播放（开）' : '顺序播放',
              ),
              ComBtn(
                icon: const Icon(
                  Icons.picture_in_picture_alt,
                  color: Colors.white,
                ),
                onTap: () => unawaited(_enterPip()),
                tooltip: '画中画',
              ),
              ComBtn(
                icon: const Icon(
                  Icons.more_vert_outlined,
                  color: Colors.white,
                ),
                onTap: () => unawaited(_showMoreSheet()),
                tooltip: '更多设置',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    // playerStatus 是普通字段，不是 Rx；播放状态变化时由 _togglePlay 自己 setState。
    // 进度、缓冲、时长是 Rx，放进 Obx 里按秒刷新。
    return _controls(
      Column(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Obx(() {
            final total = _player.duration.value;
            final progress = total <= 0
                ? 0
                : _player.position.value.clamp(0, total).toInt();
            final buffered = total <= 0
                ? 0
                : _player.buffered.value.clamp(0, total).toInt();
            return ProgressBar(
              progress: progress,
              buffered: buffered,
              total: total,
              baseBarColor: const Color(0x33FFFFFF),
              progressBarColor: Colors.white,
              bufferedBarColor: Colors.white24,
              thumbColor: Colors.white,
              thumbGlowColor: Colors.white24,
              barHeight: 3.5,
              thumbRadius: 7,
              thumbGlowRadius: 25,
              // RenderProgressBar 只有 onDragStart/onHover 非空时才参与命中
              // 测试，否则整条进度条点不动。这里给一个空回调，只为了可拖。
              onDragStart: (_) {},
              onSeek: (milliseconds) {
                _player.position.value = milliseconds ~/ 1000;
                unawaited(
                  _player.seekTo(Duration(milliseconds: milliseconds)),
                );
                _publishPipState(milliseconds);
              },
            );
          }),
          const SizedBox(height: 2),
          Row(
            children: [
              ComBtn(
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                onTap: () => unawaited(_previous()),
                tooltip: '上一条',
                width: 30,
                height: 30,
              ),
              ComBtn(
                icon: Icon(
                  _player.playerStatus.isPlaying
                      ? Icons.pause
                      : Icons.play_arrow,
                  color: Colors.white,
                ),
                onTap: () => unawaited(_togglePlay()),
                tooltip: '暂停/继续',
                width: 30,
                height: 30,
              ),
              ComBtn(
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onTap: () => unawaited(_next()),
                tooltip: '下一条',
                width: 30,
                height: 30,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Obx(
                  () => Text(
                    '${DurationUtils.formatDuration(_player.position.value)}'
                    ' / '
                    '${DurationUtils.formatDuration(_player.duration.value)}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // 右侧五个入口在窄屏（6S/SE）上整体等比缩小，不换行、不溢出。
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _speedButton(),
                        _qualityButton(),
                        Obx(() {
                          final volume = _player.volume.value;
                          return ComBtn(
                            icon: Icon(
                              volume <= 0
                                  ? Icons.volume_off
                                  : volume < 0.5
                                  ? Icons.volume_down
                                  : Icons.volume_up,
                              color: Colors.white,
                              size: 20,
                            ),
                            onTap: _showVolumeSheet,
                            tooltip: '音量',
                            width: 30,
                            height: 30,
                          );
                        }),
                        ComBtn(
                          icon: const Icon(
                            Icons.screen_rotation_alt,
                            color: Colors.white,
                            size: 20,
                          ),
                          onTap: _rotateVideo,
                          tooltip: '画面旋转',
                          width: 30,
                          height: 30,
                        ),
                        ComBtn(
                          icon: const Icon(
                            Icons.more_vert_outlined,
                            color: Colors.white,
                            size: 20,
                          ),
                          onTap: () => unawaited(_showMoreSheet()),
                          tooltip: '更多设置',
                          width: 30,
                          height: 30,
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

  Widget _speedButton() {
    return Obx(
      () => PopupMenuButton<double>(
        tooltip: '倍速',
        requestFocus: false,
        padding: EdgeInsets.zero,
        initialValue: _player.playbackSpeed,
        color: Colors.black.withValues(alpha: 0.8),
        onSelected: (speed) => unawaited(_player.setPlaybackSpeed(speed)),
        itemBuilder: (context) => _player.speedList
            .map(
              (speed) => PopupMenuItem<double>(
                height: 35,
                padding: const EdgeInsets.only(left: 30),
                value: speed,
                child: Text(
                  '${speed}X',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            )
            .toList(),
        child: SizedBox(
          width: 34,
          height: 30,
          child: Center(
            child: Text(
              '${_player.playbackSpeed}X',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }

  /// 抖音/TikTok 的播放地址没有清晰度字段，这里不伪造档位：显示当前值
  /// 「默认」并置灰，点开只说明原因。
  Widget _qualityButton() {
    return PopupMenuButton<int>(
      tooltip: '画质',
      requestFocus: false,
      padding: EdgeInsets.zero,
      color: Colors.black.withValues(alpha: 0.8),
      itemBuilder: (context) => const [
        PopupMenuItem<int>(
          enabled: false,
          height: 35,
          child: Text(
            '接口未提供分辨率',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      ],
      child: const SizedBox(
        width: 34,
        height: 30,
        child: Center(
          child: Text(
            '默认',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      ),
    );
  }

  void _rotateVideo() {
    setState(() => _quarterTurns = (_quarterTurns + 1) % 4);
  }

  Widget _sheetHeader(String title, {VoidCallback? onBack}) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: const Icon(
                Icons.arrow_back_ios_new,
                size: 16,
                color: Colors.white70,
              ),
            )
          else
            const SizedBox(width: 16),
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _sheetTile({
    required IconData icon,
    required String title,
    String? subtitle,
    bool enabled = true,
    VoidCallback? onTap,
  }) {
    return ListTile(
      dense: true,
      enabled: enabled,
      onTap: onTap,
      leading: Icon(
        icon,
        size: 20,
        color: enabled ? Colors.white70 : Colors.white24,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: enabled ? Colors.white : Colors.white38,
          fontSize: 14,
        ),
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

  void _showVolumeSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHeader('音量'),
              _volumeBody(setSheetState: setSheetState),
            ],
          ),
        ),
      ),
    );
  }

  Widget _volumeBody({required StateSetter setSheetState}) {
    final max = _player.maxVolume;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text(
                '媒体音量',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const Spacer(),
              Text(
                '${(_volume * 100).round()}%',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
          Slider(
            value: _volume.clamp(0.0, max).toDouble(),
            max: max,
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
            onChanged: (value) {
              _volume = value;
              unawaited(_player.setVolume(value, showIndicator: false));
              setSheetState(() {});
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showMoreSheet() {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (_) {
        // 0 = 更多设置，1 = 倍速，2 = 音量。子页留在同一个 sheet 里，
        // 避免「关一个再开一个」时和路由动画打架。
        var page = 0;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final Widget body;
            switch (page) {
              case 1:
                body = _speedListBody(
                  onBack: () => setSheetState(() => page = 0),
                );
              case 2:
                body = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _sheetHeader(
                      '音量',
                      onBack: () => setSheetState(() => page = 0),
                    ),
                    _volumeBody(setSheetState: setSheetState),
                  ],
                );
              default:
                body = _moreListBody(
                  onSpeed: () => setSheetState(() => page = 1),
                  onVolume: () => setSheetState(() => page = 2),
                  onRotate: () {
                    _rotateVideo();
                    setSheetState(() {});
                  },
                  onShuffle: () {
                    _toggleShuffle();
                    setSheetState(() {});
                  },
                );
            }
            return SafeArea(top: false, child: body);
          },
        );
      },
    );
  }

  Widget _moreListBody({
    required VoidCallback onSpeed,
    required VoidCallback onVolume,
    required VoidCallback onRotate,
    required VoidCallback onShuffle,
  }) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sheetHeader('更多设置'),
          _sheetTile(
            icon: Icons.speed,
            title: '倍速',
            subtitle: '${_player.playbackSpeed}X',
            onTap: onSpeed,
          ),
          _sheetTile(
            icon: Icons.high_quality_outlined,
            title: '画质',
            subtitle: '默认 · 接口未提供分辨率',
            enabled: false,
          ),
          _sheetTile(
            icon: Icons.volume_up_outlined,
            title: '音量',
            subtitle: '${(_volume * 100).round()}%',
            onTap: onVolume,
          ),
          _sheetTile(
            icon: Icons.screen_rotation_alt,
            title: '画面旋转',
            subtitle: '${_quarterTurns * 90}°',
            onTap: onRotate,
          ),
          _sheetTile(
            icon: _shuffle ? Icons.shuffle : Icons.swap_vert,
            title: '播放模式',
            subtitle: _shuffle ? '随机播放' : '顺序播放',
            onTap: onShuffle,
          ),
          _sheetTile(
            icon: Icons.picture_in_picture_alt_outlined,
            title: '画中画',
            onTap: () {
              Get.back();
              unawaited(_enterPip());
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _speedListBody({required VoidCallback onBack}) {
    return SizedBox(
      height: 300,
      child: Column(
        children: [
          _sheetHeader('倍速', onBack: onBack),
          Expanded(
            child: Obx(
              () => ListView.builder(
                itemCount: _player.speedList.length,
                itemBuilder: (context, index) {
                  final speed = _player.speedList[index];
                  final selected = _player.playbackSpeed == speed;
                  return ListTile(
                    dense: true,
                    onTap: () {
                      unawaited(_player.setPlaybackSpeed(speed));
                      Get.back();
                    },
                    title: Text(
                      '${speed}X',
                      style: TextStyle(
                        color: selected ? Colors.lightBlueAccent : Colors.white,
                        fontSize: 14,
                      ),
                    ),
                    trailing: selected
                        ? const Icon(
                            Icons.check,
                            size: 18,
                            color: Colors.lightBlueAccent,
                          )
                        : null,
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _SwipeTarget { brightness, volume }

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
