import 'dart:async';
import 'dart:math';

import 'package:PiliPlus/pages/douyin/queue.dart';
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

/// 全屏播放抖音 / TikTok 收藏。
///
/// 只有一条直链，没有 aid/cid、没有弹幕、没有清晰度梯度，所以不走 B 站视频页。
/// 但交互按 B 站播放器那套做：进度条可拖、点一下暂停/呼出控制条、
/// 左边上下滑调亮度、右边上下滑调音量、左右滑拖动进度。
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
  Timer? _ticker;
  Timer? _hideTimer;

  /// 已经解析过的播放地址（按条目 key 缓存）。
  final Map<String, QueueMedia> _resolved = {};

  late int _index;
  ShortVideoLoopMode _mode = ShortVideoLoopMode.listLoop;
  bool _playing = false;
  bool _retried = false;
  bool _fill = false;
  bool _landscape = false;
  bool _showControls = true;
  int _epoch = 0;
  int _skipped = 0;
  int _videoWidth = 0;
  int _videoHeight = 0;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration? _seekPreview;

  double _volume = 1;
  double _brightness = -1;
  double _speed = 1;

  /// 手势过程中显示的小提示（亮度 / 音量 / 快进）。
  String? _hint;
  Timer? _hintTimer;

  bool _dragOnVolume = false;
  double _dragStartValue = 0;
  Duration _dragStartPosition = Duration.zero;
  Duration _dragTarget = Duration.zero;
  bool _dragOnProgress = false;

  QueueEntry get _current => widget.queue[_index];

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
    _index = widget.index.clamp(0, widget.queue.length - 1);
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
    await _openIndex(_index);
    _scheduleHide();
  }

  /// 打开第 index 条。
  ///
  /// 抖音 / TikTok 的直链会过期，B 站还要先把 cid 和 playurl 要回来，
  /// 所以统一交给 resolveQueueEntry，解析不出来就自动跳下一条。
  Future<void> _openIndex(int index) async {
    final entry = widget.queue[index];
    _retried = false;
    // 换源要换一代画面：media_kit 重开之后纹理 id 会变，
    // 不重建这一块就会出现「只有声音没有画面」。
    _epoch++;
    _position = Duration.zero;
    _duration = Duration.zero;
    _seekPreview = null;
    var media = _resolved[entry.key];
    if (media == null) {
      media = await resolveQueueEntry(entry);
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
  }

  /// 解析不出来就跳下一条；连跳一圈还不行就停下来说清楚。
  void _skipBroken(int index) {
    if (widget.queue.length <= 1 || _skipped >= widget.queue.length) {
      _showToast('这条播不了');
      return;
    }
    _skipped++;
    final next = (index + 1) % widget.queue.length;
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

  /// 播不动就清掉缓存重新解析一次（长期地址 ⇄ 抓到的直链），还不行就跳下一条。
  void _onPlaybackError(String message) {
    if (!_retried) {
      _retried = true;
      _resolved.remove(_current.key);
      _showToast('换备用地址重试');
      _openIndex(_index);
      return;
    }
    _showToast('播放失败：$message');
    _skipBroken(_index);
  }

  void _onCompleted() {
    if (!mounted) return;
    switch (_mode) {
      case ShortVideoLoopMode.singleLoop:
        _openIndex(_index);
      case ShortVideoLoopMode.sequential:
        if (_index + 1 >= widget.queue.length) {
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
        final next = (_index + 1) % widget.queue.length;
        setState(() => _index = next);
        _openIndex(next);
    }
  }

  int _randomIndex() {
    if (widget.queue.length <= 1) return _index;
    final random = Random();
    var next = _index;
    while (next == _index) {
      next = random.nextInt(widget.queue.length);
    }
    return next;
  }

  Future<void> _jump(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= widget.queue.length) {
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
          duration: const Duration(milliseconds: 900),
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
    _ticker?.cancel();
    _hideTimer?.cancel();
    _hintTimer?.cancel();
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
                    '${_index + 1}/${widget.queue.length} · ${_current.author}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => setState(() => _fill = !_fill),
              tooltip: _fill ? '适应屏幕' : '铺满屏幕',
              icon: Icon(
                _fill ? Icons.fit_screen : Icons.aspect_ratio,
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