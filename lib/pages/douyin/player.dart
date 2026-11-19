import 'dart:async';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/rootscan.dart';
import 'package:PiliPlus/pages/douyin/shuffle_store.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/widgets/common_btn.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String? _error;
  bool _shuffle = false;

  /// 播过的 key。只用来让随机播放不重复，和「播放列表」是两回事。
  final Set<String> _played = <String>{};

  /// 是否点过小窗按钮。返回时要先把系统小窗关掉，否则页面退了自己还在后台播。
  bool _pipEntered = false;

  /// 页面已经在退，避免重复触发。
  bool _leaving = false;

  /// 当前这次横向拖动累计的位移（像素）。用来判断「滑得够不够远」，
  /// 不依赖瞬时速度——慢速拖动也应该能返回。
  double _dragDx = 0;

  QueueEntry get _current => _queue[_index];

  @override
  void initState() {
    super.initState();
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
    // 走到这里说明页面已经真的没了。不管是不是走 _leave() 出去的，都必须
    // 确保播放器被释放——否则那个单例会一直活着，下次进播放页拿到的就是
    // 一个「以为自己在播」的实例，画面/声音错位，小窗也留在后台。
    //
    // 注意不能写 `if (!_leaving)`：_leave() 会先置 _leaving = true 再 pop，
    // 于是这里永远跳过，播放器就漏了。用 _disposed 单独记一次。
    if (!_disposed) {
      unawaited(_shutdown(alreadyLeft: true));
    }
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
    // 返回必须「立刻」生效，所以顺序是：先 pop，再收尾。
    //
    // 这里踩过一个很隐蔽的坑：`_shutdown()` 虽然写了 async，但函数体里没有
    // 任何 await，所以它是一个「同步跑完的 async 函数」。调用方写
    // `unawaited(_shutdown())` 并不会让它变成后台任务——函数会一路同步执行
    // 到 `_player.dispose()` 结束才返回。而 dispose() 里面是一串原生调用
    // （关 PiP、WakelockPlus、销毁 video controller），全套跑完才轮到
    // `navigator.pop()`，中间这段时间用户看到的就是「点了返回，没反应」。
    //
    // 现在把 pop 提到最前面，收尾推到下一帧之后，让「页面消失」和
    // 「资源释放」彻底解耦。
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
    // 先同步置位，避免 dispose() 里再跑一遍收尾。
    _leaving = true;
    // 等这一帧结束再释放：pop 已经开始，原生的销毁不会再挡住退场动画。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_shutdown(alreadyLeft: true));
    });
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
            // 边缘滑返回。
            //
            // 三条硬约束，都是踩过的坑：
            //
            // 1. 必须放在 Stack 的「最下面」。命中测试是逆序遍历，排最后的
            //    那个 Positioned.fill 会先接走整屏指针，下面的控件就全哑了
            //    ——「按钮全点不动、画中画却正常」就是这么来的（画中画走原生
            //    PiP，不经过 Flutter 这一层）。
            // 2. 只用左边缘一小条，不要整屏。整屏的横向拖动会和按钮的 tap、
            //    视频的 onClick 一起进手势仲裁，拖一下就把点击吃掉。
            // 3. 上下要避开控件栏。返回按钮就在左上角，和边缘条在几何上
            //    重叠的话，手指压到它左半边就没有反应。
            Positioned(
              left: 0,
              top: MediaQuery.viewPaddingOf(context).top + _controlBarHeight,
              bottom: MediaQuery.viewPaddingOf(context).bottom + _controlBarHeight,
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
              height: MediaQuery.viewPaddingOf(context).top + _controlBarHeight,
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
                  MediaQuery.viewPaddingOf(context).bottom + _controlBarHeight,
              child: SafeArea(
                top: false,
                bottom: true,
                left: false,
                right: false,
                minimum: EdgeInsets.zero,
                child: _bottomBar(entry),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 上下控件条的高度；视频区域按这个留白，保证控件不被视频手势层覆盖。
  static const double _controlBarHeight = 68;

  /// 左边缘滑返回的响应宽度。和 iOS 系统侧滑手势的识别区宽度接近，
  /// 足够手指起手，又不会伸到中间的按钮区域去抢事件。
  static const double _edgeSwipeWidth = 20;

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
          // 结构和上游 pl_player/view/view.dart 对齐：RepaintBoundary →
          // FittedBox → SimpleVideo。
          //
          // RepaintBoundary 不是可有可无的：SimpleVideo 每帧都在
          // ListenableBuilder 里重建，没有它就会把重绘范围扩散到整个页面，
          // 6S 上表现为画面卡顿、主 isolate 被拖住。
          //
          // FittedBox 的 alignment 默认是 center，fit 用 contain，和上游
          // videoFit 在竖屏下的 BoxFit.contain 一致；aspectRatio 传 null
          // 表示按 texture 实际像素比（上游是 videoFit.aspectRatio，抖音这
          // 条没有外部画质偏好，用真实比例最稳，避免拉伸）。
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
      Row(
        // 这两条控件栏挂在 `Positioned(top/left/right)` 下，Stack 给它们的高度
        // 是**无界**的。Row 默认 mainAxisSize.max 只是横向撑满，高度方向会
        // 尽量松，子项（Icon 是定值、Text 是单行）本来没事；但加上 SafeArea
        // 之后不能再依赖默认行为，这里显式 min 掉，高度只取内容实际高度。
        // 宽度不受影响：外层还是撑满的，Expanded 依旧能占满剩余宽度。
        mainAxisSize: MainAxisSize.min,
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
