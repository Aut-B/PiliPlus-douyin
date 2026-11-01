import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome, SystemUiMode;
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';

/// 播放顺序。
enum ShortVideoLoopMode {
  listLoop('列表循环', Icons.repeat),
  singleLoop('单曲循环', Icons.repeat_one),
  sequential('顺序播放', Icons.playlist_play),
  shuffle('随机播放', Icons.shuffle);

  const ShortVideoLoopMode(this.label, this.icon);

  final String label;
  final IconData icon;

  ShortVideoLoopMode get next =>
      ShortVideoLoopMode.values[(index + 1) % ShortVideoLoopMode.values.length];
}

/// 全屏播放抖音 / TikTok / B 站收藏。
///
/// 只有一条直链，没有 aid/cid、没有弹幕、没有清晰度梯度，所以不走 B 站视频页。
/// 但交互按 B 站播放器那套做：进度条可拖、点一下暂停/呼出控制条、
/// 左边上下滑调亮度、右边上下滑调音量、左右滑拖动进度。
///
/// iOS 上还接了系统级画中画（`VideoController.setPictureInPicture`），
/// 和站内视频页用的是同一套原生实现。
class ShortVideoPlayerPage extends StatefulWidget {
  const ShortVideoPlayerPage({
    super.key,
    required this.queue,
    required this.index,
  });

  /// 播放队列：抖音 / TikTok / B 站可以混在一起。
  final List<QueueEntry> queue;
  final int index;

  @override
  State<ShortVideoPlayerPage> createState() => _ShortVideoPlayerPageState();
}

class _ShortVideoPlayerPageState extends State<ShortVideoPlayerPage> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<String>? _pipEventSub;
  StreamSubscription<String>? _pipErrorSub;
  Timer? _ticker;
  Timer? _hideTimer;

  /// 已经解析过的播放地址（按条目 key 缓存）。
  final Map<String, QueueMedia> _resolved = {};

  /// 可变的那一份队列：播到一半可以被 [QueueBus] 插队。
  late final List<QueueEntry> _queue = List<QueueEntry>.of(widget.queue);

  late int _index;
  ShortVideoLoopMode _mode = ShortVideoLoopMode.listLoop;
  bool _playing = false;

  /// 这一条已经重试到第几步：0 直链、1 备用地址、2 本地缓存。
  int _retryStage = 0;

  /// 正在处理一次播放错误（一次 open 会连报好几条）。
  bool _busy = false;
  bool _fill = false;
  bool _landscape = false;
  bool _showControls = true;
  int _epoch = 0;
  int _skipped = 0;
  int _videoWidth = 0;
  int _videoHeight = 0;

  /// iOS 画中画：系统判定不支持时把按钮藏起来。
  bool _pipSupported = true;
  bool _pipActive = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration? _seekPreview;

  double _volume = 1;
  double _brightness = -1;
  double _speed = 1;

  /// 手势过程中显示的小提示（亮度 / 音量 / 快进 / 缓存进度）。
  String? _hint;
  Timer? _hintTimer;

  bool _dragOnVolume = false;
  double _dragStartValue = 0;
  Duration _dragStartPosition = Duration.zero;
  Duration _dragTarget = Duration.zero;
  bool _dragOnProgress = false;

  QueueEntry get _current => _queue[_index];

  /// 按视频自己的比例显示，横屏的就铺成横向，竖屏的就铺成竖向。
  double get _aspectRatio {
    if (_videoWidth > 0 && _videoHeight > 0) {
      return _videoWidth / _videoHeight;
    }
    return 9 / 16;
  }

  Duration get _shownPosition => _seekPreview ?? _position;

  @override
  void initState() {
    super.initState();
    _index = widget.index.clamp(0, _queue.length - 1);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _restoreGestureState();
    _init();
  }

  Future<void> _restoreGestureState() async {
    try {
      final volume = await FlutterVolumeController.getVolume();
      if (volume != null && mounted) setState(() => _volume = volume);
    } catch (_) {}
    try {
      final brightness = await ScreenBrightnessPlatform.instance.application;
      if (mounted) setState(() => _brightness = brightness);
    } catch (_) {}
  }

  Future<void> _init() async {
    final player = await Player.create(
      configuration: const PlayerConfiguration(
        options: {'autoplay': 'yes'},
      ),
    );
    final controller = await VideoController.create(player);
    if (!mounted) {
      player.dispose();
      return;
    }

    _playingSub = player.stream.playing.listen((value) {
      if (mounted) setState(() => _playing = value);
    });
    _completedSub = player.stream.completed.listen((completed) {
      if (completed) _onCompleted();
    });
    _errorSub = player.stream.error.listen((message) {
      if (!mounted || message.isEmpty) return;
      _onPlaybackError(message);
    });

    // 这个 fork 的 PlayerStream 没有 width/height，位置和时长从 state 上读。
    _ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final current = _player;
      if (current == null || !mounted) return;
      final position = current.state.position;
      final duration = current.state.duration;
      if (position == _position && duration == _duration) return;
      setState(() {
        _position = position;
        _duration = duration;
      });
    });

    setState(() {
      _player = player;
      _controller = controller;
    });
    _listenPip(controller);
    await _openIndex(_index);
    _scheduleHide();
  }

  // MARK: - 画中画（iOS 系统级）

  void _listenPip(VideoController controller) {
    if (!Platform.isIOS) return;
    _pipEventSub ??= PictureInPicture.events.listen((event) {
      if (!mounted) return;
      switch (event) {
        case 'start':
          setState(() => _pipActive = true);
        case 'restore':
        case 'stop':
          setState(() => _pipActive = false);
      }
    });
    _pipErrorSub ??= PictureInPicture.errors.listen((message) {
      if (!mounted) return;
      setState(() => _pipActive = false);
      _showToast(message);
    });
    // 「后台画中画」开关开着时，划回主屏幕自动弹小窗。
    if (Pref.autoPiP) {
      unawaited(
        Future<void>.sync(
          () => controller.setAutoEnterPictureInPicture(true),
        ).catchError((_) {}),
      );
    }
  }

  Future<void> _togglePip() async {
    final controller = _controller;
    if (controller == null || !Platform.isIOS) return;
    try {
      if (_pipActive) {
        await controller.setPictureInPicture(false);
        if (mounted) setState(() => _pipActive = false);
        return;
      }
      final supported = await controller.isPictureInPictureSupported();
      if (!mounted) return;
      if (!supported) {
        setState(() => _pipSupported = false);
        _showToast('当前机型不支持画中画（系统判定）');
        return;
      }
      await controller.setPictureInPicture(true);
      if (mounted) setState(() => _pipActive = true);
    } catch (e) {
      if (mounted) setState(() => _pipActive = false);
      _showToast('画中画启动失败：$e');
    }
  }

  /// 播放页里直接把抖音 / TikTok 的视频插到「下一首」。
  ///
  /// 收藏列表那边也能加插队，但那样得先退出播放页——播放器就没了。
  /// 所以播放页自己也留了一个入口。
  Future<void> _openQueuePicker() async {
    final all = ShortVideoRepo.loadAll();
    if (all.isEmpty) {
      _showToast('还没有抓到抖音 / TikTok 收藏');
      return;
    }
    final picked = await showModalBottomSheet<ShortVideo>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (context) => _QueuePickerSheet(videos: all),
    );
    if (picked == null || !mounted) return;
    final entry = QueueEntry.fromShortVideo(picked);
    if (entry.key == _current.key) {
      _showToast('正在播的就是这条');
      return;
    }
    _queue.insert(_index + 1, entry);
    setState(() {});
    _showToast('已插到下一首：${picked.title}');
  }

  /// 打开第 index 条。
  ///
  /// 抖音 / TikTok 的直链会过期，B 站还要先把 cid 和 playurl 要回来，
  /// 所以统一交给 resolveQueueEntry，解析不出来就自动跳下一条。
  Future<void> _openIndex(int index, {bool resetRetry = true}) async {
    final entry = _queue[index];
    if (resetRetry) _retryStage = 0;
    // 换源要换一代画面：media_kit 重开之后纹理 id 会变，
    // 不重建这一块就会出现「只有声音没有画面」。
    _epoch++;
    _position = Duration.zero;
    _duration = Duration.zero;
    _seekPreview = null;
    var media = _resolved[entry.key];
    if (media == null) {
      media = await _resolve(entry);
      if (media == null) {
        _skipBroken(index);
        return;
      }
      _resolved[entry.key] = media;
    }
    final player = _player;
    if (player == null || !mounted) return;
    player.setMediaHeader(
      userAgent: media.userAgent,
      referer: media.referer,
    );
    await player.open(Media(media.url), play: true);
    await player.setRate(_speed);
    _skipped = 0;
    _syncVideoSize();
    if (_pipActive) {
      final controller = _controller;
      if (controller != null) {
        unawaited(
          Future<void>.sync(
            () => controller.preparePictureInPictureForNewMedia(),
          ).catchError((_) {}),
        );
      }
    }
  }

  /// 本地已经有缓存就直接播本地（TikTok 基本都走这条）。
  Future<QueueMedia?> _resolve(QueueEntry entry) async {
    final video = entry.short;
    if (video != null) {
      final local = await ShortVideoMediaCache.localPath(video);
      if (local != null) {
        final platform =
            ShortVideoPlatform.fromId(video.platform) ??
            ShortVideoPlatform.douyin;
        return QueueMedia(
          url: local,
          userAgent: platform.userAgent,
          referer: platform.referer,
          isLocal: true,
        );
      }
    }
    return resolveQueueEntry(entry);
  }

  /// 解析不出来就跳下一条；连跳一圈还不行就停下来说清楚。
  void _skipBroken(int index) {
    if (_queue.length <= 1 || _skipped >= _queue.length) {
      _showToast('这条播不了');
      return;
    }
    _skipped++;
    final next = (index + 1) % _queue.length;
    if (!mounted) return;
    setState(() => _index = next);
    _openIndex(next);
  }

  /// 这个 fork 的 `PlayerStream` 没有 width/height，只能从 `state` 上取；
  /// 换源之后要等几百毫秒才有值，所以轮询几次。
  void _syncVideoSize() {
    var tries = 0;
    Future.doWhile(() async {
      if (!mounted) return false;
      final player = _player;
      if (player != null) {
        final w = player.state.width;
        final h = player.state.height;
        if (w > 0 && h > 0) {
          if (w != _videoWidth || h != _videoHeight) {
            setState(() {
              _videoWidth = w;
              _videoHeight = h;
            });
          }
          return false;
        }
      }
      tries++;
      if (tries > 40) return false;
      await Future.delayed(const Duration(milliseconds: 250));
      return true;
    });
  }

  /// 播不动就分三级退：换备用地址 → 缓存到本地 → 跳下一条。
  ///
  /// media_kit 一次 open 往往会连报好几条 error，所以这里串行化：
  /// 处理期间再来的错误直接丢掉，否则会一路退到「缓存」和「跳下一条」。
  Future<void> _onPlaybackError(String message) async {
    if (_busy) return;
    _busy = true;
    try {
      final entry = _current;
      if (_retryStage == 0) {
        _retryStage = 1;
        _resolved.remove(entry.key);
        _showToast('换备用地址重试');
        await _openIndex(_index, resetRetry: false);
        return;
      }
      if (_retryStage == 1 && entry.short != null) {
        _retryStage = 2;
        await _cacheAndPlay(entry);
        return;
      }
      _showToast('播放失败：$message');
      _skipBroken(_index);
    } finally {
      _busy = false;
    }
  }
  /// 直链怎么都播不了：用 HttpClient 整条下下来再播（TikTok 的老毛病）。
  Future<void> _cacheAndPlay(QueueEntry entry) async {
    final video = entry.short;
    if (video == null) {
      _skipBroken(_index);
      return;
    }
    // 本地文件也播不了 → 别再循环下载，直接跳。
    if (await ShortVideoMediaCache.localPath(video) != null) {
      _showToast('缓存文件也播不了');
      _skipBroken(_index);
      return;
    }
    final platform =
        ShortVideoPlatform.fromId(video.platform) ?? ShortVideoPlatform.douyin;
    final urls = <String>[
      if (video.playUrl.isNotEmpty) video.playUrl,
      ...stableUrls(video),
    ];
    if (!mounted) return;
    setState(() => _hint = '缓存中 0%');
    final path = await ShortVideoMediaCache.download(
      video,
      urls: urls,
      userAgent: platform.userAgent,
      referer: platform.referer,
      onProgress: (progress) {
        if (!mounted) return;
        final percent = (progress * 100).round();
        if (_hint == '缓存中 $percent%') return;
        setState(() => _hint = '缓存中 $percent%');
      },
    );
    if (!mounted) return;
    setState(() => _hint = null);
    if (path == null) {
      _showToast('直链和缓存都失败了');
      _skipBroken(_index);
      return;
    }
    _retryStage = 0;
    _resolved[entry.key] = QueueMedia(
      url: path,
      userAgent: platform.userAgent,
      referer: platform.referer,
      isLocal: true,
    );
    _showToast('已缓存到本地，重新播放');
    await _openIndex(_index, resetRetry: false);
  }

  void _onCompleted() {
    if (!mounted) return;
    // 「下一首播放」插队优先于本页的播放顺序。
    if (_playInjectedNext()) return;
    switch (_mode) {
      case ShortVideoLoopMode.singleLoop:
        _openIndex(_index);
      case ShortVideoLoopMode.sequential:
        if (_index + 1 >= _queue.length) {
          _showToast('已经是最后一条');
          return;
        }
        setState(() => _index += 1);
        _openIndex(_index);
      case ShortVideoLoopMode.shuffle:
        final next = _randomIndex();
        setState(() => _index = next);
        _openIndex(next);
      case ShortVideoLoopMode.listLoop:
        final next = (_index + 1) % _queue.length;
        setState(() => _index = next);
        _openIndex(next);
    }
  }

  /// 从 [QueueBus] 取一条插到当前条目后面。取到了返回 true。
  bool _playInjectedNext() {
    final injected = QueueBus.takeNext();
    if (injected == null) return false;
    if (injected.key == _current.key) {
      // 正在播的那条又被排进来了，顺延到下一条。
      return _playInjectedNext();
    }
    _queue.insert(_index + 1, injected);
    setState(() => _index += 1);
    _openIndex(_index);
    return true;
  }

  int _randomIndex() {
    if (_queue.length <= 1) return _index;
    final random = Random();
    var next = _index;
    while (next == _index) {
      next = random.nextInt(_queue.length);
    }
    return next;
  }

  Future<void> _jump(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= _queue.length) {
      _showToast(delta > 0 ? '已经是最后一条' : '已经是第一条');
      return;
    }
    setState(() => _index = next);
    await _openIndex(next);
  }

  void _cycleMode() {
    setState(() => _mode = _mode.next);
    _showToast(_mode.label);
  }

  void _cycleSpeed() {
    const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    setState(() => _speed = next);
    _player?.setRate(next);
    _showToast('${next}x');
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _showControls = false);
    });
  }

  void _flashHint(String text) {
    _hintTimer?.cancel();
    setState(() => _hint = text);
    _hintTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  // MARK: - 手势

  void _onVerticalStart(DragStartDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    _dragOnVolume = details.localPosition.dx > width / 2;
    _dragStartValue = _dragOnVolume
        ? _volume
        : (_brightness < 0 ? 0.5 : _brightness);
  }

  void _onVerticalUpdate(DragUpdateDetails details) {
    final height = MediaQuery.sizeOf(context).height;
    final delta = -details.delta.dy / height * 1.2;
    final next = (_dragStartValue + delta).clamp(0.0, 1.0);
    _dragStartValue = next;
    if (_dragOnVolume) {
      setState(() => _volume = next);
      FlutterVolumeController.updateShowSystemUI(false);
      FlutterVolumeController.setVolume(next);
      _flashHint('音量 ${(next * 100).round()}%');
    } else {
      setState(() => _brightness = next);
      ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(next);
      _flashHint('亮度 ${(next * 100).round()}%');
    }
  }

  void _onHorizontalStart(DragStartDetails details) {
    _dragOnProgress = true;
    _dragStartPosition = _position;
    _dragTarget = _position;
  }

  void _onHorizontalUpdate(DragUpdateDetails details) {
    if (!_dragOnProgress || _duration == Duration.zero) return;
    final width = MediaQuery.sizeOf(context).width;
    // 全屏横向拉满大约扫过整条视频。
    final deltaMs =
        (details.delta.dx / width) * _duration.inMilliseconds * 0.6;
    var target = _dragTarget + Duration(milliseconds: deltaMs.round());
    if (target < Duration.zero) target = Duration.zero;
    if (target > _duration) target = _duration;
    _dragTarget = target;
    setState(() => _seekPreview = target);
    _flashHint(
      '${_fmt(target)} / ${_fmt(_duration)}',
    );
  }

  void _onHorizontalEnd(DragEndDetails details) {
    if (!_dragOnProgress) return;
    _dragOnProgress = false;
    final target = _dragTarget;
    setState(() {
      _seekPreview = null;
      _position = target;
    });
    _player?.seek(target);
  }

  Future<void> _seekTo(Duration target) async {
    setState(() {
      _position = target;
      _seekPreview = null;
    });
    await _player?.seek(target);
  }

  void _toggleLandscape() {
    setState(() => _landscape = !_landscape);
    if (_landscape) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _scheduleHide();
  }

  void _showToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(milliseconds: 1200),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  static String _fmt(Duration value) {
    final total = value.inSeconds;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    final hours = minutes ~/ 60;
    if (hours > 0) {
      return '$hours:${(minutes % 60).toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _playingSub?.cancel();
    _errorSub?.cancel();
    _pipEventSub?.cancel();
    _pipErrorSub?.cancel();
    _ticker?.cancel();
    _hideTimer?.cancel();
    _hintTimer?.cancel();
    if (_pipActive) {
      // 小窗还开着就退出这一页：先收小窗，再把播放器交还。
      _controller?.setPictureInPicture(false);
    }
    _player?.dispose();
    ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // 退出这一页后把方向交还给 App（Info.plist 里允许的就是这三个）。
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onVerticalDragStart: _onVerticalStart,
            onVerticalDragUpdate: _onVerticalUpdate,
            onHorizontalDragStart: _onHorizontalStart,
            onHorizontalDragUpdate: _onHorizontalUpdate,
            onHorizontalDragEnd: _onHorizontalEnd,
            child: controller == null
                ? const Center(child: CircularProgressIndicator())
                : _videoView(controller),
          ),
          if (_hint != null)
            IgnorePointer(
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _hint!,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ),
              ),
            ),
          if (_showControls) _topBar(),
          if (_showControls) _bottomBar(),
        ],
      ),
    );
  }

  Widget _topBar() {
    final pending = QueueBus.pending;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 6,
          left: 6,
          right: 6,
          bottom: 10,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: () => Get.back(),
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _current.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  Text(
                    '${_index + 1}/${_queue.length} · ${_current.author}'
                    '${pending > 0 ? ' · 插队 $pending' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: _openQueuePicker,
              tooltip: '插到下一首播放',
              icon: const Icon(Icons.playlist_add, color: Colors.white),
            ),
            IconButton(
              onPressed: () => setState(() => _fill = !_fill),
              tooltip: _fill ? '适应屏幕' : '铺满屏幕',
              icon: Icon(
                _fill ? Icons.fit_screen : Icons.aspect_ratio,
                color: Colors.white,
              ),
            ),
            if (Platform.isIOS && _pipSupported)
              IconButton(
                onPressed: _togglePip,
                tooltip: _pipActive ? '退出画中画' : '画中画',
                icon: Icon(
                  _pipActive
                      ? Icons.picture_in_picture_alt
                      : Icons.picture_in_picture_outlined,
                  color: Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final total = _duration.inMilliseconds;
    final progress = total <= 0
        ? 0.0
        : (_shownPosition.inMilliseconds / total).clamp(0.0, 1.0);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          bottom: MediaQuery.of(context).padding.bottom + 10,
          top: 18,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: progress,
                onChangeStart: (_) {
                  _hideTimer?.cancel();
                  setState(() => _seekPreview = _position);
                },
                onChanged: (value) {
                  if (total <= 0) return;
                  setState(() {
                    _seekPreview = Duration(
                      milliseconds: (value * total).round(),
                    );
                  });
                },
                onChangeEnd: (value) {
                  if (total <= 0) return;
                  _seekTo(Duration(milliseconds: (value * total).round()));
                  _scheduleHide();
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  Text(
                    _fmt(_shownPosition),
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  const Spacer(),
                  Text(
                    _fmt(_duration),
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  onPressed: () => _jump(-1),
                  icon: const Icon(Icons.skip_previous, color: Colors.white),
                ),
                IconButton(
                  iconSize: 42,
                  onPressed: () => _player?.playOrPause(),
                  icon: Icon(
                    _playing ? Icons.pause_circle : Icons.play_circle,
                    color: Colors.white,
                    size: 42,
                  ),
                ),
                IconButton(
                  onPressed: () => _jump(1),
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                ),
                IconButton(
                  onPressed: _cycleMode,
                  tooltip: _mode.label,
                  icon: Icon(_mode.icon, color: Colors.white),
                ),
                TextButton(
                  onPressed: _cycleSpeed,
                  child: Text(
                    '${_speed}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                IconButton(
                  onPressed: _toggleLandscape,
                  tooltip: _landscape ? '竖屏' : '全屏',
                  icon: Icon(
                    _landscape ? Icons.crop_portrait : Icons.fullscreen,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoView(VideoController controller) {
    final video = SimpleVideo(
      key: ValueKey(_epoch),
      controller: controller,
      fill: Colors.black,
      aspectRatio: _aspectRatio,
    );
    if (_fill) {
      // 铺满：按原比例放大到盖住整屏，多出来的裁掉（抖音那种全屏观感）。
      return ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 1000,
              height: 1000 / _aspectRatio,
              child: video,
            ),
          ),
        ),
      );
    }
    return Center(child: AspectRatio(aspectRatio: _aspectRatio, child: video));
  }
}

/// 播放页里挑一条抖音 / TikTok 视频插到「下一首」。
class _QueuePickerSheet extends StatefulWidget {
  const _QueuePickerSheet({required this.videos});

  final List<ShortVideo> videos;

  @override
  State<_QueuePickerSheet> createState() => _QueuePickerSheetState();
}

class _QueuePickerSheetState extends State<_QueuePickerSheet> {
  String _platform = 'douyin';

  @override
  Widget build(BuildContext context) {
    final items = widget.videos.where((e) => e.platform == _platform).toList();
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '插到下一首播放',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                _tab('douyin', '抖音'),
                _tab('tiktok', 'TikTok'),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    '${items.length} 条',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '这个平台还没有收藏',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final video = items[index];
                        return ListTile(
                          dense: true,
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              width: 36,
                              height: 48,
                              child: video.cover.isEmpty
                                  ? const ColoredBox(color: Colors.black26)
                                  : Image.network(
                                      video.cover,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) =>
                                          const ColoredBox(color: Colors.black26),
                                    ),
                            ),
                          ),
                          title: Text(
                            video.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                          subtitle: Text(
                            video.durationText,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          trailing: const Icon(
                            Icons.playlist_add,
                            color: Colors.white70,
                          ),
                          onTap: () => Navigator.of(context).pop(video),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tab(String id, String label) {
    final active = _platform == id;
    return TextButton(
      onPressed: () => setState(() => _platform = id),
      child: Text(
        label,
        style: TextStyle(
          color: active ? Colors.white : Colors.white54,
          fontWeight: active ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}