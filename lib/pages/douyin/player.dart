import 'dart:async';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/shuffle_store.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 抖音 / TikTok / B 站收藏的整页播放器。
///
/// 这一版是重建后的干净实现，刻意保持小：
///
/// * 只做「播一条、上下切条、点一下暂停、进小窗」这四件事；
/// * 复用上游 `PlPlayerController`，因此画中画走的是 PiliPlus 自己那套
///   `PipPlugin`（从 Flutter texture 抓帧、CIImage 转格式、系统时基做时间戳），
///   不再自建一条 PiP 帧管道；
/// * 不在这里做任何 QA 埋点。QA 是另一条独立链路，不参与播放逻辑。
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
  String? _error;
  bool _shuffle = false;

  /// 播过的 key。只用来让随机播放不重复，和「播放列表」是两回事。
  final Set<String> _played = <String>{};

  QueueEntry get _current => _queue[_index];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_open(_index));
      unawaited(_restoreShuffle());
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 把某一条解析成可以直接交给播放器的地址，然后开播。
  Future<void> _open(int index) async {
    if (_opening || _queue.isEmpty) return;
    final target = index.clamp(0, _queue.length - 1);
    _opening = true;
    try {
      final entry = _queue[target];
      setState(() {
        _index = target;
        _error = null;
      });
      // TikTok 的 CDN 按网页会话校验，必须带上 WKWebView 那罐 cookie，
      // 否则「地址解析出来了、一播就 403」。
      var cookie = '';
      final video = entry.short;
      if (video != null) {
        final platform = ShortVideoPlatform.fromId(video.platform) ??
            ShortVideoPlatform.douyin;
        cookie = await ShortVideoWeb.cookieHeader(platform.cookieDomainNeedle);
      }
      if (!mounted) return;
      final media = await resolveQueueEntry(entry, cookie: cookie);
      if (!mounted) return;
      if (media == null || media.url.isEmpty) {
        setState(() => _error = '解析不出播放地址');
        return;
      }
      await _player.setDataSource(
        NetworkSource(videoSource: media.url, audioSource: null),
        autoplay: true,
      );
      if (!mounted) return;
      _notePlayed(entry.key);
    } catch (error) {
      if (mounted) setState(() => _error = '播放失败：$error');
    } finally {
      _opening = false;
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

  Future<void> _togglePlay() async {
    if (_player.playerStatus.isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _enterPip() async {
    if (!IOSPipHelper.isAvailable) {
      SmartDialog.showToast('这台设备不支持画中画');
      return;
    }
    _player.enterPip(autoEnter: true);
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _video()),
            Positioned(top: 8, left: 8, right: 8, child: _topBar(entry)),
            Positioned(bottom: 12, left: 8, right: 8, child: _bottomBar(entry)),
          ],
        ),
      ),
    );
  }

  Widget _video() {
    if (_error != null) {
      return Center(
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
            TextButton(
              onPressed: _next,
              child: const Text('下一条'),
            ),
          ],
        ),
      );
    }
    final controller = _player.videoController;
    if (controller == null) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_togglePlay()),
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: SimpleVideo(
            controller: controller,
            fill: Colors.black,
            aspectRatio: null,
          ),
        ),
      ),
    );
  }

  Widget _topBar(QueueEntry entry) {
    return Row(
      children: [
        ComBtn(
          icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
          onTap: () => Navigator.maybePop(context),
        ),
        Expanded(
          child: Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white),
          ),
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
      ],
    );
  }

  Widget _bottomBar(QueueEntry entry) {
    // playerStatus 是普通字段，不是 Rx；播放状态变化时由 _togglePlay 自己 setState。
    return Row(
      children: [
        ComBtn(
          icon: const Icon(Icons.skip_previous, color: Colors.white),
          onTap: () => unawaited(_previous()),
        ),
        ComBtn(
          icon: Icon(
            _player.playerStatus.isPlaying
                ? Icons.pause
                : Icons.play_arrow,
            color: Colors.white,
          ),
          onTap: () => unawaited(_togglePlay()),
        ),
        ComBtn(
          icon: const Icon(Icons.skip_next, color: Colors.white),
          onTap: () => unawaited(_next()),
        ),
        const Spacer(),
        Text(
          '${_index + 1}/${_queue.length}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
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
