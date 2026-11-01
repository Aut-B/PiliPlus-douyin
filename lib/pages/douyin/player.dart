import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, SystemChrome;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
/// 直接用 media_kit，而不是走 B 站视频页：这里没有 aid/cid、没有弹幕、没有
/// 清晰度梯度，只有一条直链，加上用户要的列表循环 / 单曲循环 / 顺序 / 随机。
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
  StreamSubscription<String>? _errorSub;

  /// 已经探测过的播放地址（按 `platform:id` 缓存）。
  final Map<String, String> _resolved = {};

  late int _index;
  ShortVideoLoopMode _mode = ShortVideoLoopMode.listLoop;
  bool _playing = false;
  bool _retried = false;
  int _videoWidth = 0;
  int _videoHeight = 0;

  ShortVideo get _current => widget.videos[_index];

  ShortVideoPlatform get _platform =>
      ShortVideoPlatform.fromId(_current.platform) ?? ShortVideoPlatform.douyin;

  /// 按视频自己的比例显示，横屏的就铺成横向，竖屏的就铺成竖向——不再强行 9:16。
  double get _aspectRatio {
    if (_videoWidth > 0 && _videoHeight > 0) {
      return _videoWidth / _videoHeight;
    }
    return 9 / 16;
  }

  @override
  void initState() {
    super.initState();
    _index = widget.index.clamp(0, widget.videos.length - 1);
    // 竖屏视频很多，但也有横屏的；这一页允许横过来。
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
    _errorSub = player.stream.error.listen((message) {
      if (!mounted || message.isEmpty) return;
      _onPlaybackError(message);
    });

    setState(() {
      _player = player;
      _controller = controller;
    });
    await _openIndex(_index);
  }

  /// 打开第 `index` 条。
  ///
  /// 网页里抄到的直链带过期签名（两小时左右），放久了、同步到别的手机都会
  /// 陆续播不了。这里优先用 `video_id` 的长期地址（先探一下通不通），
  /// 不通再退回抓到的直链。
  Future<void> _openIndex(int index) async {
    final video = widget.videos[index];
    _retried = false;
    var url = _resolved[video.key];
    if (url == null) {
      // 刚抓下来的签名直链最稳、也没有探测延迟；超过 30 分钟（放久了，
      // 或者是从另一台手机同步过来的）才去要不过期的地址。
      final age = DateTime.now().millisecondsSinceEpoch / 1000 - video.updatedAt;
      final fresh = video.updatedAt > 0 && age >= 0 && age < 30 * 60;
      final stable = video.stableUrl;
      if (!fresh && stable != null && await _probe(stable, video)) {
        url = stable;
      } else {
        url = video.playUrl;
      }
      _resolved[video.key] = url;
    }
    await _player?.open(Media(url), play: true);
    _syncVideoSize();
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

  /// 只取两个字节确认能播，别把整段视频拉下来。
  Future<bool> _probe(String url, ShortVideo video) async {
    final platform =
        ShortVideoPlatform.fromId(video.platform) ?? ShortVideoPlatform.douyin;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
      request.headers.set(HttpHeaders.userAgentHeader, platform.userAgent);
      request.headers.set(HttpHeaders.refererHeader, platform.referer);
      final response = await request.close().timeout(const Duration(seconds: 6));
      final mime = response.headers.contentType?.mimeType ?? '';
      final ok =
          (response.statusCode == 200 || response.statusCode == 206) &&
          !mime.contains('html');
      await response.drain<void>();
      return ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 播不动先换另一个地址再试一次（长期地址 ⇄ 抓到的直链）。
  void _onPlaybackError(String message) {
    final video = _current;
    final resolved = _resolved[video.key];
    if (!_retried && resolved != null && resolved != video.playUrl) {
      _retried = true;
      _resolved[video.key] = video.playUrl;
      _showToast('换备用地址重试');
      _openIndex(_index);
      return;
    }
    _showToast('播放失败：$message');
  }

  void _onCompleted() {
    if (!mounted) return;
    switch (_mode) {
      case ShortVideoLoopMode.singleLoop:
        _openIndex(_index);
      case ShortVideoLoopMode.sequential:
        if (_index + 1 >= widget.videos.length) {
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
        final next = (_index + 1) % widget.videos.length;
        setState(() => _index = next);
        _openIndex(next);
    }
  }

  int _randomIndex() {
    if (widget.videos.length <= 1) return _index;
    final random = Random();
    var next = _index;
    while (next == _index) {
      next = random.nextInt(widget.videos.length);
    }
    return next;
  }

  Future<void> _jump(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= widget.videos.length) return;
    setState(() => _index = next);
    await _openIndex(next);
  }

  void _cycleMode() {
    setState(() => _mode = _mode.next);
    _showToast(_mode.label);
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
    _errorSub?.cancel();
    _player?.dispose();
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
                  aspectRatio: _aspectRatio,
                  child: SimpleVideo(
                    controller: controller,
                    fill: Colors.black,
                    aspectRatio: _aspectRatio,
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
                    onPressed: _cycleMode,
                    tooltip: _mode.label,
                    icon: Icon(_mode.icon, color: Colors.white),
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
                      const SizedBox(width: 12),
                      Text(
                        _mode.label,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
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