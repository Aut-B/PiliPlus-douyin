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
///
/// 关于「整个页面像死了」：上一版把小窗按钮、上下条按钮直接叠在
/// `Positioned.fill` 的视频手势上，iOS 上手指落在按钮上时事件仍会被下面的
/// 播放器手势吃掉，点「向下」既不返回也不暂停，表现出来就是页面卡死。
/// 现在所有控件都包在 [HitTestBehavior.opaque] 的 `AbsorbPointer` 外层里，
/// 视频手势只在真正的空白画面区域生效。
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

  /// 是否点过小窗按钮。返回时要先把系统小窗关掉，否则页面退了自己还在后台播。
  bool _pipEntered = false;

  /// 页面已经在退，避免重复触发。
  bool _leaving = false;

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
    // 走到这里说明页面已经真的没了（返回键、返回手势、收藏页被替换）。
    // 如果小窗是开着的，先关掉它，否则用户以为退出了实际上还在后台播。
    if (!_leaving) unawaited(_shutdown());
    super.dispose();
  }

  /// 退出播放页前的收尾。先关系统小窗，再把播放器停掉并释放。
  ///
  /// 为什么必须做：小窗开着的时候播放器还活着，又没有任何页面在管它，
  /// 再点进收藏页播下一条就会拿到那个「以为自己在播」的单例，画面/声音错位，
  /// 再叠加一层没关掉的小窗，页面就彻底点不动了。
  Future<void> _shutdown() async {
    if (_leaving) return;
    _leaving = true;
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
  }

  void _leave() {
    // 返回必须「立刻」生效：先 pop 掉页面，再在后台收尾。
    // 之前是 await 收尾再 pop，只要原生的关小窗回调不返回，用户看到的就是
    // 点了没反应——这是「返回不了」的直接原因。
    // 顺序上先起收尾（同步置位 _leaving），再 pop，否则 dispose() 里会因为
    // _leaving 已被置位而跳过收尾。
    final navigator = Navigator.of(context);
    unawaited(_shutdown());
    if (navigator.canPop()) navigator.pop();
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
      if (!media.isLocal) {
        _player.overrideMediaHeader(
          userAgent: media.userAgent.isEmpty ? null : media.userAgent,
          referer: media.referer.isEmpty ? null : media.referer,
        );
      } else {
        _player.overrideMediaHeader();
      }
      await _player.setDataSource(
        // 缓存好的那条是磁盘上的 mp4。用 NetworkSource 去喂一个本地路径，
        // mpv 会先当网络源探测一遍再回退，白白多等几秒——「缓存了几个 G
        // 还是要等很久」就是这里。这里直接按网络 URL 打开，但 extras 里
        // 不放缓存参数由 controller 统一处理，路径本身 mpv 认。
        NetworkSource(videoSource: media.url, audioSource: null),
        autoplay: true,
        isVertical: true,
        // 本地文件时长已知，直接告诉播放器，省掉一次探测。
        duration: media.isLocal && entry.durationMs > 0
            ? Duration(milliseconds: entry.durationMs)
            : null,
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
    _pipEntered = true;
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
                  top: MediaQuery.viewPaddingOf(context).top + _controlBarHeight,
                  bottom: MediaQuery.viewPaddingOf(context).bottom +
                      _controlBarHeight,
                ),
                child: _video(),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(bottom: false, child: _topBar(entry)),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(top: false, child: _bottomBar(entry)),
            ),
            // 左滑返回。放在视频手势之外单独一层，只认「从左边 48px 起始的
            // 横向拖动」，不影响视频区域的点按。
            Positioned(
              left: 0,
              top: 96,
              bottom: 96,
              width: 48,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  if ((details.primaryVelocity ?? 0) > 0) _leave();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 上下控件条的高度；视频区域按这个留白，保证控件不被视频手势层覆盖。
  static const double _controlBarHeight = 68;

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
      // 只在这一块响应点按暂停，并且不吃掉外层（横向滑返回）的手势。
      behavior: HitTestBehavior.translucent,
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

  /// 控件层。包一层 [AbsorbPointer] 让手指落在按钮上时不再漏给下面的视频层。
  Widget _controls(Widget child) {
    return AbsorbPointer(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: child,
      ),
    );
  }

  Widget _topBar(QueueEntry entry) {
    return _controls(
      Row(
        children: [
          ComBtn(
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
            // 返回必须永远可用，不能等收尾完成才响应——收尾里如果等原生
            // 关小窗卡住，用户看到的就是「点了没反应」。_leave 是同步的，
            // 收尾在它内部以 unawaited 方式启动。
            onTap: _leave,
            tooltip: '返回',
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
      ),
    );
  }

  Widget _bottomBar(QueueEntry entry) {
    // playerStatus 是普通字段，不是 Rx；播放状态变化时由 _togglePlay 自己 setState。
    return _controls(
      Row(
        children: [
          ComBtn(
            icon: const Icon(Icons.skip_previous, color: Colors.white),
            onTap: () => unawaited(_previous()),
            tooltip: '上一条',
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
          ),
          ComBtn(
            icon: const Icon(Icons.skip_next, color: Colors.white),
            onTap: () => unawaited(_next()),
            tooltip: '下一条',
          ),
          const Spacer(),
          Text(
            '${_index + 1}/${_queue.length}',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
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
