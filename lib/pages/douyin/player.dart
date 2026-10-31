import 'dart:async';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 全屏播放抖音 / TikTok 收藏。
///
/// 直接用 media_kit，而不是走 B 站视频页：这里没有 aid/cid、没有弹幕、没有
/// 清晰度梯度，只有一条直链，加上用户要的单曲 / 列表循环。
class ShortVideoPlayerPage extends StatefulWidget {
  const ShortVideoPlayerPage({
    super.key,
    required this.videos,
    required this.index,
  });

  final List<ShortVideo> videos;
  final int index;

  @override
  State<ShortVideoPlayerPage> createState() => _ShortVideoPlayerPageState();
}

class _ShortVideoPlayerPageState extends State<ShortVideoPlayerPage> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<bool>? _playingSub;

  late int _index;
  bool _singleLoop = false;
  bool _playing = false;

  ShortVideo get _current => widget.videos[_index];

  ShortVideoPlatform get _platform =>
      ShortVideoPlatform.fromId(_current.platform) ?? ShortVideoPlatform.douyin;

  @override
  void initState() {
    super.initState();
    _index = widget.index.clamp(0, widget.videos.length - 1);
    _init();
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
    player.setMediaHeader(
      userAgent: _platform.userAgent,
      referer: _platform.referer,
    );
    _playingSub = player.stream.playing.listen((value) {
      if (mounted) setState(() => _playing = value);
    });
    _completedSub = player.stream.completed.listen((completed) {
      if (completed) _onCompleted();
    });
    setState(() {
      _player = player;
      _controller = controller;
    });
    await player.open(Media(_current.playUrl), play: true);
  }

  void _onCompleted() {
    if (!mounted) return;
    if (_singleLoop) {
      _player?.open(Media(_current.playUrl), play: true);
      return;
    }
    final next = (_index + 1) % widget.videos.length;
    setState(() => _index = next);
    _player?.open(Media(_current.playUrl), play: true);
  }

  Future<void> _jump(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= widget.videos.length) return;
    setState(() => _index = next);
    await _player?.open(Media(_current.playUrl), play: true);
  }

  void _toggleLoop() {
    setState(() => _singleLoop = !_singleLoop);
    _showToast(_singleLoop ? '单个循环' : '列表循环');
  }

  void _showToast(String text) {
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

  @override
  void dispose() {
    _completedSub?.cancel();
    _playingSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _player?.playOrPause(),
        onVerticalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -200) {
            _jump(1);
          } else if (velocity > 200) {
            _jump(-1);
          }
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (controller == null)
              const Center(child: CircularProgressIndicator())
            else
              Center(
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: SimpleVideo(
                    controller: controller,
                    fill: Colors.black,
                  ),
                ),
              ),
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Get.back(),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      _current.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                  ),
                  IconButton(
                    onPressed: _toggleLoop,
                    tooltip: _singleLoop ? '单个循环' : '列表循环',
                    icon: Icon(
                      _singleLoop ? Icons.repeat_one : Icons.repeat,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            if (!_playing && controller != null)
              const IgnorePointer(
                child: Center(
                  child: Icon(
                    Icons.play_circle_fill,
                    size: 72,
                    color: Colors.white70,
                  ),
                ),
              ),
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _current.author,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _roundButton(
                        icon: Icons.keyboard_arrow_up,
                        onTap: () => _jump(-1),
                      ),
                      const SizedBox(width: 12),
                      _roundButton(
                        icon: Icons.keyboard_arrow_down,
                        onTap: () => _jump(1),
                      ),
                      const Spacer(),
                      Text(
                        '${_index + 1} / ${widget.videos.length}',
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.white24,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}