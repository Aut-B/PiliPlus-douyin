import 'dart:async' show unawaited;

import 'package:PiliPlus/common/style.dart' show Style;
import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/pages/douyin/auto_cache.dart';
import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/diag_probe.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/playlist.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:PiliPlus/pages/douyin/rootscan_view.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/services.dart' show Clipboard;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 用户点「删除」时的两种真实意图：只清本地文件，或把收藏一起删掉。
enum _DeleteMode { cacheOnly, removeFavorite }

/// 抖音 / TikTok 收藏的入口页：顶部一排平台切换，下面是选中平台的收藏。
///
/// 导航栏的枚举项必须是编译期常量，所以那里只能放这个无参页面；
/// 具体平台的收藏列表由它按当前选择构建。
class ShortVideoPage extends StatefulWidget {
  const ShortVideoPage({super.key});

  @override
  State<ShortVideoPage> createState() => _ShortVideoPageState();
}

class _ShortVideoPageState extends State<ShortVideoPage> {
  ShortVideoPlatform _platform = ShortVideoPlatform.douyin;

  /// 多选状态放在两个平台之上，切换 Tab 时选择不丢。
  ///
  /// 这里存的是 `ShortVideo` 本身而不只是 key：切到另一个 Tab 后，
  /// 当前页拿不到另一边的 `_videos`，批量加入播放列表还得靠这些对象。
  bool _selecting = false;
  final Map<String, ShortVideo> _selected = <String, ShortVideo>{};

  void _setSelecting(bool value) {
    setState(() {
      _selecting = value;
      if (!value) _selected.clear();
    });
  }

  void _toggleSelect(ShortVideo video) {
    setState(() {
      if (_selected.remove(video.key) == null) {
        _selected[video.key] = video;
      }
    });
  }

  /// 全选只作用于当前 Tab：已经选中的另一平台条目保留。
  void _toggleAll(Iterable<ShortVideo> videos) {
    final list = videos.toList(growable: false);
    if (list.isEmpty) return;
    final allSelected = list.every((e) => _selected.containsKey(e.key));
    setState(() {
      if (allSelected) {
        for (final video in list) {
          _selected.remove(video.key);
        }
      } else {
        for (final video in list) {
          _selected[video.key] = video;
        }
      }
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _removeSelected(Iterable<ShortVideo> videos) {
    setState(() {
      for (final video in videos) {
        _selected.remove(video.key);
      }
      if (_selected.isEmpty) _selecting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 只保留收藏页自己的 Scaffold：平台切换直接放进 AppBar 标题行，
    // 避免外面再套一层 AppBar 出现两条标题栏。
    return ShortVideoFavoritesPage(
      key: ValueKey(_platform.id),
      platform: _platform,
      onPlatformChanged: (value) {
        if (value == _platform) return;
        setState(() => _platform = value);
      },
      selecting: _selecting,
      selected: _selected,
      onSelectingChanged: _setSelecting,
      onToggleSelect: _toggleSelect,
      onToggleAll: _toggleAll,
      onRemoveSelected: _removeSelected,
    );
  }
}

/// 抖音 / TikTok 收藏列表。
///
/// 抓取本身在原生 WKWebView 里做（网页登录 + 旁观接口返回），这里只负责
/// 展示、播放和 WebDAV 同步。
class ShortVideoFavoritesPage extends StatefulWidget {
  const ShortVideoFavoritesPage({
    super.key,
    required this.platform,
    required this.onPlatformChanged,
    required this.selecting,
    required this.selected,
    required this.onSelectingChanged,
    required this.onToggleSelect,
    required this.onToggleAll,
    required this.onRemoveSelected,
  });

  final ShortVideoPlatform platform;
  final ValueChanged<ShortVideoPlatform> onPlatformChanged;
  final bool selecting;
  final Map<String, ShortVideo> selected;
  final ValueChanged<bool> onSelectingChanged;
  final ValueChanged<ShortVideo> onToggleSelect;
  final ValueChanged<Iterable<ShortVideo>> onToggleAll;
  final ValueChanged<Iterable<ShortVideo>> onRemoveSelected;

  @override
  State<ShortVideoFavoritesPage> createState() =>
      _ShortVideoFavoritesPageState();
}

class _ShortVideoFavoritesPageState extends State<ShortVideoFavoritesPage> {
  /// 主界面底部导航栏的遮挡高度。它叠画在本页 body 之上，不吃布局，
  /// 所以本页自己要留出这段高度，否则最后一行按钮会被压住点不到。
  ///
  /// 两种形态都要覆盖：
  /// * 悬浮导航栏：64 的胶囊 + 8 的底部内边距 = 72；
  /// * 默认的 Material NavigationBar：80。
  ///
  /// 取 88 是为了在较高的那种上面再留一点呼吸空间。这里不是 56：
  /// 56 只够旧的 BottomNavigationBar，默认的 M3 导航栏比它高 24。
  static const double _mainBottomNavHeight = 88;

  /// 上滑收起底栏时累计位移的封顶值，约等于 M3 导航栏高度。
  static const double _bottomBarHideOffset = 80;

  /// 底栏收起进度：0 为完全展开，[_bottomBarHideOffset] 为完全收起。
  final ValueNotifier<double> _barOffset = ValueNotifier<double>(0);

  /// 主界面悬浮四 tab 导航栏的位移，与 B站首页 `CommonPageState` 共用
  /// 同一个 Rx（量纲是 `Style.topBarHeight`）。用户在设置里关掉「隐藏底栏」
  /// 时该值为 null，此时只收起本页自己的操作条。
  RxDouble? _mainBarOffset;

  final List<ShortVideo> _videos = [];
  bool _syncing = false;
  String _status = '';

  /// 原生一共回传了多少段响应（不等于视频条数）。
  int _rawCount = 0;

  /// 本次抓取会话的已知 id 集合：已同步 + 当前列表 + 墓碑。
  /// 每段响应只做字符串判重，不再反复解码本地缓存。
  Set<String> _knownKeys = <String>{};

  /// 正在把选中的条目下到本地。
  bool _caching = false;

  /// 已缓存条目。卡片角标、按钮状态和批量操作都读这里，避免每帧都查文件。
  final Set<String> _cachedKeys = <String>{};

  /// 单条下载进度，key 是 [ShortVideo.key]。
  final Map<String, double> _cacheProgress = <String, double>{};
  final Map<String, int> _cacheProgressAt = <String, int>{};
  int _cacheDone = 0;
  int _cacheTotal = 0;
  int _cacheScanId = 0;

  /// 本地缓存目录占用（字节）。
  int _cacheBytes = 0;

  ShortVideoPlatform get platform => widget.platform;

  bool get _selecting => widget.selecting;
  Iterable<ShortVideo> get _selectedVideos => widget.selected.values;
  int get _selectedCount => widget.selected.length;

  /// 当前 Tab 里被选中的条目。缓存 / 删除只对它生效。
  List<ShortVideo> get _localSelected => _selectedVideos
      .where((e) => e.platform == platform.id)
      .toList(growable: false);

  bool get _allLocalSelected =>
      _videos.isNotEmpty &&
      _videos.every((e) => widget.selected.containsKey(e.key));

  @override
  void initState() {
    super.initState();
    _mainBarOffset = Get.isRegistered<MainController>()
        ? Get.find<MainController>().barOffset
        : null;
    _reload();
    _refreshCacheSize();
    _status = _videos.isEmpty
        ? '还没有抓取到收藏，点下面「打开网页」登录后抓取'
        : '本地 ${_videos.length} 条';
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSync());
  }

  /// 上滑累计正位移收起底栏，下滑再退回来；只跟随手指拖动，
  /// 松手后的惯性滚动不改位移，避免回弹闪动。
  bool _onScrollNotification(ScrollNotification notification) {
    if (_videos.isEmpty || notification.metrics.axis == Axis.horizontal) {
      return false;
    }
    final double delta;
    if (notification is ScrollUpdateNotification) {
      if (notification.dragDetails == null) return false;
      delta = notification.scrollDelta ?? 0;
    } else if (notification is OverscrollNotification) {
      delta = notification.overscroll;
    } else {
      return false;
    }
    if (delta == 0) return false;
    // 列表在顶部继续下拉时不要收起底栏（与 CommonPageState 一致）。
    if (notification.metrics.pixels < 0 && delta > 0) return false;
    _barOffset.value = clampDouble(
      _barOffset.value + delta,
      0.0,
      _bottomBarHideOffset,
    );
    final mainBarOffset = _mainBarOffset;
    if (mainBarOffset != null) {
      mainBarOffset.value = clampDouble(
        mainBarOffset.value + delta,
        0.0,
        Style.topBarHeight,
      );
    }
    return false;
  }

  /// 本页操作条与主界面悬浮导航栏一起回到展开状态。
  void _resetBarOffset() {
    _barOffset.value = 0;
    final mainBarOffset = _mainBarOffset;
    if (mainBarOffset != null && mainBarOffset.value != 0) {
      mainBarOffset.value = 0;
    }
  }

  @override
  void dispose() {
    // 切到别的 tab 时本页可能带着主界面底栏的位移一起消失：延到下一帧
    // 复位，避免在销毁过程中触发主界面重建。主界面控制器若已关闭，
    // 写入会被 Rx 自己忽略。
    final mainBarOffset = _mainBarOffset;
    if (mainBarOffset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        mainBarOffset.value = 0;
      });
    }
    _barOffset.dispose();
    super.dispose();
  }

  void _reload() {
    final stored = ShortVideoRepo.load(platform);
    if (!mounted) return;
    // 切换平台/重新拉取后列表回到顶部，底栏也跟着展开。
    _resetBarOffset();
    setState(() {
      _videos
        ..clear()
        ..addAll(stored);
    });
    unawaited(_backfillMeta());
    unawaited(_refreshCachedState());
  }

  /// 旧版「从链接导入」只写了占位文案，元数据是空的。列表加载后串行、
  /// 限量地回视频页补一次标题 / 作者 / 封面 / 时长，失败就跳过。
  /// 不阻塞 UI，也不和播放抢同一条视频的解析。
  static const int _metaBackfillLimit = 8;
  bool _metaBackfilling = false;

  static bool _needsMeta(ShortVideo video) =>
      video.videoId.isNotEmpty &&
      (video.desc.trim().isEmpty ||
          video.desc.trim() == '分享链接添加的视频' ||
          video.author.trim().isEmpty);

  Future<void> _backfillMeta() async {
    if (_metaBackfilling) return;
    final targets = _videos
        .where(_needsMeta)
        .take(_metaBackfillLimit)
        .toList(growable: false);
    if (targets.isEmpty) return;
    _metaBackfilling = true;
    try {
      for (final target in targets) {
        if (!mounted) return;
        final key = target.key;
        if (!_videos.any((e) => e.key == key && _needsMeta(e))) continue;
        final resolved = await ShortVideoWeb.resolvePlayUrl(
          platformId: target.platform,
          videoId: target.videoId,
          userAgent: platform.mobileUserAgent,
          force: true,
        );
        if (!mounted) return;
        if (resolved == null) continue;
        final index = _videos.indexWhere((e) => e.key == key);
        if (index < 0) continue;
        final current = _videos[index];
        final title = resolved.title.trim();
        final author = resolved.author.trim();
        final cover = resolved.cover.trim();
        final durationMs = resolved.durationMs;
        // 一个字段都没补到就别写回，省得反复解析。
        if (title.isEmpty &&
            author.isEmpty &&
            cover.isEmpty &&
            durationMs <= 0) {
          continue;
        }
        final updated = current.copyWith(
          desc: title.isEmpty || title == current.desc ? null : title,
          author: author.isEmpty ? null : author,
          cover: cover.isEmpty ? null : cover,
          durationMs: durationMs > 0 ? durationMs : null,
        );
        setState(() => _videos[index] = updated);
        ShortVideoRepo.save(platform, _videos);
      }
    } finally {
      _metaBackfilling = false;
    }
  }

  Future<void> _autoSync() async {
    if (!ShortVideoSync.configured) return;
    await _sync(silent: true);
  }

  Future<void> _sync({bool silent = false}) async {
    if (_syncing) return;
    if (!ShortVideoSync.configured) {
      SmartDialog.showToast('还没配置 WebDAV：设置 → WebDAV 设置');
      return;
    }
    setState(() => _syncing = true);
    try {
      final result = await ShortVideoSync.synchronize();
      if (!mounted) return;
      _reload();
      ShortVideoAutoCache.schedule();
      var text = '已同步：${result.summary}（${result.counts}）';
      if (_videos.isEmpty && result.total > 0) {
        // 总数不为 0、本页却是空的：说明那些条目不属于当前平台，
        // 或者落库失败。两种都在 summary 里写清楚了，别再说「同步成功」。
        text =
            '同步到 ${result.total} 条，但${platform.album}一条都没有（${result.summary}）';
      } else if (_videos.isNotEmpty) {
        text = '$text；本页 ${_videos.length} 条';
      }
      setState(() => _status = text);
      if (!silent) SmartDialog.showToast(text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '同步失败：$e');
      if (!silent) SmartDialog.showToast('同步失败: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// 网页弹层是否正在打开，避免连点叠两个。
  bool _openingWeb = false;

  /// 网页里是否明确处于未登录状态；由原生状态文字驱动。
  bool _webLoggedOut = false;

  void _installWebHandlers() {
    _rawCount = 0;
    _knownKeys = <String>{
      ...ShortVideoRepo.loadSynced(platform),
      ..._videos.map((e) => e.key),
      ...ShortVideoRepo.loadDeleted(platform),
    };
    ShortVideoWeb.onPayload = _ingest;
    ShortVideoWeb.onStatus = (text) {
      if (!mounted) return;
      setState(() {
        _status = text;
        if (text.contains('未登录')) {
          _webLoggedOut = true;
        } else if (text.contains('已登录') || text.contains('登录成功')) {
          _webLoggedOut = false;
        }
      });
    };
    ShortVideoWeb.onClosed = () {
      if (!mounted) return;
      _reload();
      // 未登录提示保留到下次真的检测到登录态：关掉网页也能看到
      // 「未登录，点右上角登录」，不会以为已经登录过了。
      setState(() => _status = '本地 ${_videos.length} 条');
      ShortVideoAutoCache.schedule();
      _sync(silent: true);
    };
  }

  Future<void> _openWeb() async {
    if (_openingWeb) return;
    _openingWeb = true;
    _installWebHandlers();
    try {
      // 把本地已有条数带下去：抓够这么多就不再无限滚动翻旧数据。
      await ShortVideoWeb.open(platform, knownCount: _videos.length);
    } catch (e) {
      if (mounted) setState(() => _status = '打开网页失败：$e');
      SmartDialog.showToast('打开网页失败: $e');
    } finally {
      _openingWeb = false;
      // 网页是独立路由，回来时把底栏展开，别停在上次滚动的收起态。
      if (mounted) _resetBarOffset();
    }
  }

  /// 直接同步：打开收藏页后立刻开始抓取，只把新增 id 解析入库。
  ///
  /// 平台接口要签名，Dart 侧不能直接请求；这里复用原生 WKWebView，并在
  /// `open` 之后马上调 `start`，由原生自己切到收藏页、按本地条数尽早停止
  /// 翻旧页。增量语义由 `_ingest` 保证：滚多少页都只解析新增。
  Future<void> _directSync() async {
    if (_openingWeb) return;
    _openingWeb = true;
    _installWebHandlers();
    try {
      await ShortVideoWeb.open(
        platform,
        knownCount: _videos.length,
        autoStart: true,
      );
      if (mounted) {
        setState(() => _status = '直连同步：只拉取新增收藏…');
      }
    } catch (e) {
      if (mounted) setState(() => _status = '直连同步失败：$e');
      SmartDialog.showToast('直连同步失败: $e');
    } finally {
      _openingWeb = false;
      // 与打开网页一致：独立路由返回后把底栏展开。
      if (mounted) _resetBarOffset();
    }
  }

  void _ingest(String body) {
    _rawCount++;
    // 命中的条目连字段都不解析；墓碑里的 key 也跳过，遵守「本地为准」，
    // 不会被平台重新抓回来。
    final result = ShortVideoParser.parseIncremental(
      body,
      platform,
      knownKeys: _knownKeys,
    );
    final added = <ShortVideo>[
      for (final video in result.videos)
        if (_knownKeys.add(video.key)) video,
    ];
    debugPrint(
      '[fav-sync] capture#$_rawCount new=${added.length} '
      'skipped=${result.skipped} deleted=0 parsed=${result.parsed}',
    );
    if (added.isEmpty) {
      if (mounted && result.parsed == 0) {
        setState(
          () => _status =
              '收到 $_rawCount 段数据，无新增'
              '（跳过 ${result.skipped} 条）',
        );
      }
      return;
    }
    _videos.addAll(added);
    ShortVideoRepo.save(platform, _videos);
    ShortVideoAutoCache.schedule();
    if (mounted) {
      setState(
        () => _status =
            '新增 ${added.length} 条，跳过 ${result.skipped} 条，'
            '本地 ${_videos.length} 条',
      );
    }
  }

  /// 正在从分享链接解析并加入一条收藏。
  bool _addingLink = false;

  /// 上一次链接解析失败是否需要用户去网页登录后再试。
  bool _linkNeedsLogin = false;

  Future<String?> _askShareLink() async {
    var initial = '';
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      initial = data?.text?.trim() ?? '';
    } catch (_) {}
    if (!mounted) return null;
    var text = initial;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('粘贴链接添加'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('把抖音 / TikTok App 里的分享链接粘贴到这里，只加这一条，不用登录网页。'),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: initial,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                hintText:
                    'https://v.douyin.com/… 或 '
                    'https://www.tiktok.com/@…/video/…',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => text = value,
              onFieldSubmitted: (value) =>
                  Navigator.of(dialogContext).pop(value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _linkFailed(String message, {bool login = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _linkNeedsLogin = login;
    });
    SmartDialog.showToast(message);
  }

  /// 从一条分享链接加入收藏：短链先展开，再要一条可播直链，最后落库。
  ///
  /// 全程只复用现有的原生直链解析，不碰收藏夹登录和整套抓取流程。
  Future<void> _addFromLink() async {
    if (_addingLink) return;
    final input = await _askShareLink();
    if (!mounted || input == null) return;
    var link = ShortVideoShareLink.parse(input);
    if (link == null) {
      _linkFailed('没识别到视频 id，请粘贴完整分享链接');
      return;
    }
    setState(() {
      _addingLink = true;
      _linkNeedsLogin = false;
    });
    try {
      if (!link.hasVideoId) {
        setState(() => _status = '正在展开短链…');
        final expanded = await ShortVideoWeb.expandShortLink(
          link.shortUrl!,
          userAgent: link.platform.mobileUserAgent,
        );
        final reparsed = expanded == null
            ? null
            : ShortVideoShareLink.parse(expanded);
        if (reparsed == null || !reparsed.hasVideoId) {
          _linkFailed(
            '短链展开失败，请检查网络，或粘贴带视频 id 的完整链接',
          );
          return;
        }
        link = reparsed;
      }
      final target = link.platform;
      final key = link.key;
      final existing = target == platform
          ? _videos
          : ShortVideoRepo.load(target);
      if (existing.any((e) => e.key == key)) {
        _linkFailed(
          target == platform
              ? '这条视频已经在${target.album}收藏里了'
              : '这条视频已经在${target.album}收藏里了，切到上方查看',
        );
        return;
      }
      if (mounted) setState(() => _status = '正在解析可播放直链…');
      final resolved = await ShortVideoWeb.resolvePlayUrl(
        platformId: target.id,
        videoId: link.videoId,
        userAgent: target.mobileUserAgent,
        force: true,
      );
      if (!mounted) return;
      if (resolved == null || resolved.url.isEmpty) {
        switch (ShortVideoWeb.lastPlayUrlError) {
          case 'network':
            _linkFailed('网络请求失败，请检查网络后重试', login: true);
          case 'login':
            _linkFailed('需要登录网页后才能解析，请登录后再试', login: true);
          case 'notfound':
            _linkFailed(
              '没解析到可播放直链，请打开网页登录后再试',
              login: true,
            );
          default:
            _linkFailed('没拿到可播放直链，请稍后再试', login: true);
        }
        return;
      }
      final title = resolved.title.trim();
      final video = ShortVideo(
        id: link.videoId,
        platform: target.id,
        desc: title,
        author: resolved.author.trim(),
        cover: resolved.cover.trim(),
        durationMs: resolved.durationMs,
        playUrl: resolved.url,
        videoId: link.videoId,
        updatedAt: DateTime.now().millisecondsSinceEpoch / 1000,
      );
      existing.insert(0, video);
      final written = ShortVideoRepo.save(target, existing);
      if (written < 0) {
        existing.removeWhere((e) => e.key == key);
        _linkFailed('保存失败，请检查存储空间');
        return;
      }
      ShortVideoRepo.unmarkDeleted(target, <String>[key]);
      if (target == platform) {
        if (!mounted) return;
        setState(() {
          _knownKeys.add(key);
          _status = '已添加 1 条，本地 ${_videos.length} 条，点列表即可播放';
        });
        ShortVideoAutoCache.schedule();
      } else {
        if (!mounted) return;
        setState(
          () => _status = '已加入${target.album}收藏，切到上方${target.album}查看',
        );
      }
      SmartDialog.showToast(
        target == platform ? '已添加，点列表即可播放' : '已加入${target.album}收藏',
      );
    } finally {
      if (mounted) setState(() => _addingLink = false);
    }
  }

  /// 播放页打开期间置位，避免连点把两个播放页叠在一起。
  bool _openingPlayer = false;

  /// 把播放页 push 到收藏页上面，而不是替换掉当前路由。
  ///
  /// B 站收藏夹点进视频后退出会回到原列表（含滚动位置）；这里以前用
  /// `Get.off` 把 MainApp 整条路由换掉，退出只能重建首页，收藏 Tab 也就丢了。
  Future<void> _openQueue(List<QueueEntry> queue, int index) async {
    if (_openingPlayer || queue.isEmpty) return;
    _openingPlayer = true;
    try {
      await openShortVideoQueue(queue, index);
    } finally {
      _openingPlayer = false;
      // 播放页是独立路由，本页底栏不参与其竖滑；退出回来时重新展开。
      if (mounted) _resetBarOffset();
    }
  }

  void _play(int index) {
    if (_videos.isEmpty) return;
    unawaited(
      _openQueue(_videos.map(QueueEntry.fromShortVideo).toList(), index),
    );
  }

  /// 只播选中的这些（按勾选顺序，可跨抖音 / TikTok）。
  void _playSelected() {
    final queue = _selectedVideos.toList(growable: false);
    if (queue.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    widget.onSelectingChanged(false);
    unawaited(_openQueue(queue.map(QueueEntry.fromShortVideo).toList(), 0));
  }

  void _toggleSelect(ShortVideo video) => widget.onToggleSelect(video);

  void _toggleSelectMode() => widget.onSelectingChanged(!_selecting);

  void _selectAll() => widget.onToggleAll(_videos);

  void _playAll() => _play(0);

  Future<void> _clear() async {
    final keys = _videos.map((e) => e.key).toList();
    final videos = List<ShortVideo>.of(_videos);
    final positions = List<int>.generate(videos.length, (i) => i);
    setState(() {
      _videos.clear();
      _cachedKeys.clear();
      _status = '已清空，可重新抓取';
    });
    widget.onSelectingChanged(false);
    ShortVideoRepo.save(platform, const []);
    // 留墓碑：否则下一次同步会把这些条目从远端并回来。
    ShortVideoRepo.markDeleted(platform, keys);
    for (final video in videos) {
      if (!ShortVideoPlaylistRepo.contains('short:${video.key}')) {
        await ShortVideoMediaCache.remove(video);
      }
    }
    ShortVideoAutoCache.refreshProtection();
    _offerUndo(videos, positions);
    if (ShortVideoSync.configured) await _sync(silent: true);
  }

  /// 删除前先问清楚：只清本地文件，还是连收藏条目一起删。
  Future<_DeleteMode?> _askDeleteMode({
    required String title,
    required String detail,
  }) {
    return showDialog<_DeleteMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_DeleteMode.cacheOnly),
            child: const Text('只删本地缓存'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_DeleteMode.removeFavorite),
            child: const Text('删除收藏（含缓存）'),
          ),
        ],
      ),
    );
  }

  /// 只删本地视频文件：收藏条目、删除墓碑和播放列表都不动。
  Future<void> _removeCacheOnly(List<ShortVideo> videos) async {
    for (final video in videos) {
      await ShortVideoMediaCache.remove(video);
    }
    if (!mounted) return;
    setState(() {
      for (final video in videos) {
        _cachedKeys.remove(video.key);
      }
      _status = '已清理 ${videos.length} 条的本地缓存，收藏保留';
    });
    await _refreshCacheSize();
    if (mounted) {
      SmartDialog.showToast('已清理 ${videos.length} 条的本地缓存，收藏仍在');
    }
  }

  /// 删一条：本地列表 + 删除墓碑 + 本地缓存文件。
  Future<void> _deleteOne(ShortVideo video) async {
    final mode = await _askDeleteMode(
      title: '删除这条收藏？',
      detail:
          '${video.title}\n\n'
          '只删本地缓存：收藏条目保留，之后可自动补回；\n'
          '删除收藏：本机移除这一条并写删除墓碑，下次同步时远端那份也会被排除（6 秒内可撤销）。',
    );
    if (mode == null || !mounted) return;
    if (mode == _DeleteMode.cacheOnly) {
      await _removeCacheOnly([video]);
      return;
    }
    final position = _videos.indexWhere((e) => e.key == video.key);
    setState(() {
      _videos.removeWhere((e) => e.key == video.key);
      _cachedKeys.remove(video.key);
      _status = '已删除 1 条，本地 ${_videos.length} 条';
    });
    widget.onRemoveSelected([video]);
    ShortVideoRepo.save(platform, _videos);
    ShortVideoRepo.markDeleted(platform, [video.key]);
    if (!ShortVideoPlaylistRepo.contains('short:${video.key}')) {
      await ShortVideoMediaCache.remove(video);
    }
    ShortVideoAutoCache.refreshProtection();
    _offerUndo([video], [position < 0 ? _videos.length : position]);
    if (ShortVideoSync.configured) await _sync(silent: true);
  }

  /// 多选删除。
  Future<void> _deleteSelected() async {
    final targets = _localSelected;
    if (targets.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    final mode = await _askDeleteMode(
      title: '处理所选的 ${targets.length} 条？',
      detail:
          '只删本地缓存：清掉本机的视频文件，收藏条目全部保留，之后可自动补回；\n'
          '删除收藏：从本机列表移除并写删除墓碑，下次同步时远端那份也会被排除（6 秒内可撤销）。',
    );
    if (mode == null || !mounted) return;
    if (mode == _DeleteMode.cacheOnly) {
      await _removeCacheOnly(targets);
      return;
    }
    final positions = <int>[
      for (final video in targets)
        _videos.indexWhere((e) => e.key == video.key),
    ];
    setState(() {
      _videos.removeWhere((e) => targets.any((t) => t.key == e.key));
      for (final video in targets) {
        _cachedKeys.remove(video.key);
      }
      _status = '已删除 ${targets.length} 条，本地 ${_videos.length} 条';
    });
    widget.onRemoveSelected(targets);
    ShortVideoRepo.save(platform, _videos);
    ShortVideoRepo.markDeleted(platform, targets.map((e) => e.key));
    for (final video in targets) {
      if (!ShortVideoPlaylistRepo.contains('short:${video.key}')) {
        await ShortVideoMediaCache.remove(video);
      }
    }
    ShortVideoAutoCache.refreshProtection();
    _offerUndo(targets, [
      for (final position in positions)
        position < 0 ? _videos.length : position,
    ]);
    if (ShortVideoSync.configured) await _sync(silent: true);
  }

  /// 删除后给一次「撤销」。
  ///
  /// 误删收藏的代价太大：远端那份会被墓碑排掉，只能重新登录、重新抓一遍。
  /// 所以删除只改本地，并且留 6 秒的后悔药。
  void _offerUndo(List<ShortVideo> removed, List<int> positions) {
    if (removed.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除 ${removed.length} 条'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () => _undoDelete(removed, positions),
          ),
        ),
      );
  }

  Future<void> _undoDelete(
    List<ShortVideo> removed,
    List<int> positions,
  ) async {
    ShortVideoRepo.unmarkDeleted(platform, removed.map((e) => e.key));
    // 撤销要算一次「本地更新」：远端增量里可能还留着这条的删除记录，
    // updatedAt 更晚才会被当成新增推回去，而不是又被远端删除带走。
    final now = DateTime.now().millisecondsSinceEpoch.toDouble();
    setState(() {
      for (var i = 0; i < removed.length; i++) {
        final video = removed[i].copyWith(updatedAt: now);
        if (_videos.any((e) => e.key == video.key)) continue;
        final at = (i < positions.length ? positions[i] : _videos.length).clamp(
          0,
          _videos.length,
        );
        _videos.insert(at, video);
      }
      _status = '已恢复 ${removed.length} 条，本地 ${_videos.length} 条';
    });
    ShortVideoRepo.save(platform, _videos);
    ShortVideoAutoCache.schedule();
    if (ShortVideoSync.configured) await _sync(silent: true);
  }

  /// 刷新本地缓存占用。
  Future<void> _refreshCacheSize() async {
    final bytes = await ShortVideoMediaCache.size();
    if (!mounted || bytes == _cacheBytes) return;
    setState(() => _cacheBytes = bytes);
  }

  /// 扫描当前列表哪些条目已经有完整本地文件。
  ///
  /// 只做一次目录里的文件存在性检查，不在 build 里逐条 await。
  Future<void> _refreshCachedState() async {
    final scanId = ++_cacheScanId;
    final videos = List<ShortVideo>.of(_videos);
    final cached = <String>{};
    for (final video in videos) {
      if (!mounted || scanId != _cacheScanId) return;
      if (await ShortVideoMediaCache.localPath(video) != null) {
        cached.add(video.key);
      }
    }
    if (!mounted || scanId != _cacheScanId) return;
    if (cached.length == _cachedKeys.length &&
        cached.containsAll(_cachedKeys)) {
      return;
    }
    setState(() {
      _cachedKeys
        ..clear()
        ..addAll(cached);
    });
  }

  /// 清空短视频缓存目录。
  Future<void> _clearCache() async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('清空本地缓存？'),
      content: Text(
        '会删掉已经下到本机的 ${_fmtBytes(_cacheBytes)} 视频文件。'
        '收藏列表和 WebDAV 上的记录不受影响，收藏与播放列表里的视频会自动补回。',
      ),
    );
    if (!confirmed || !mounted) return;
    await ShortVideoMediaCache.clear();
    if (mounted) {
      setState(() {
        _cachedKeys.clear();
        _cacheProgress.clear();
      });
    }
    await _refreshCacheSize();
    ShortVideoAutoCache.schedule();
    if (mounted) SmartDialog.showToast('缓存已清空，正在自动补回收藏');
  }

  /// 把选中的条目整条下到本地。
  ///
  /// 串行下载：低内存机型上并发下载会直接把进程顶掉，CDN 也会限速。
  /// 下过一次之后播放直接读文件，不再反复探测直链。
  Future<void> _cacheVideos(List<ShortVideo> videos) async {
    if (videos.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    if (_caching) {
      SmartDialog.showToast('正在缓存中');
      return;
    }
    ShortVideoAutoCache.refreshProtection();
    setState(() {
      _caching = true;
      _cacheDone = 0;
      _cacheTotal = videos.length;
      _cacheProgress.clear();
      _cacheProgressAt.clear();
    });
    var ok = 0;
    var skipped = 0;
    final cookie = await ShortVideoWeb.cookieHeader(
      platform.cookieDomainNeedle,
    );
    for (var i = 0; i < videos.length; i++) {
      if (!mounted) break;
      final video = videos[i];
      final existing = await ShortVideoMediaCache.localPath(video);
      if (existing != null) {
        skipped++;
        if (mounted) {
          setState(() {
            _cachedKeys.add(video.key);
            _cacheDone = i + 1;
          });
        }
        continue;
      }
      if (!mounted) break;
      setState(() {
        _cacheProgress[video.key] = 0;
        _status = '缓存中 ${i + 1}/${videos.length}：${video.title}';
      });
      final urls = <String>[
        if (video.playUrl.isNotEmpty) video.playUrl,
        ...stableUrls(video),
      ];
      final total = videos.length;
      final result = await ShortVideoMediaCache.download(
        video,
        urls: urls,
        userAgent: platform.userAgent,
        referer: platform.referer,
        cookie: cookie,
        appUserAgent: platform == ShortVideoPlatform.tiktok
            ? tiktokAppUserAgent
            : '',
        onProgress: (progress) {
          if (!mounted) return;
          final now = DateTime.now().millisecondsSinceEpoch;
          final last = _cacheProgressAt[video.key] ?? 0;
          if (progress < 1 && now - last < 180) return;
          _cacheProgressAt[video.key] = now;
          setState(() {
            _cacheProgress[video.key] = progress.clamp(0.0, 1.0);
            _status =
                '缓存中 ${i + 1}/$total'
                '（${(progress * 100).clamp(0, 100).round()}%）：'
                '${video.title}';
          });
        },
      );
      if (!mounted) break;
      if (result.ok) {
        ok++;
        setState(() {
          _cacheProgress.remove(video.key);
          _cacheProgressAt.remove(video.key);
          _cacheDone = i + 1;
          _cachedKeys.add(video.key);
        });
      } else {
        setState(() {
          _cacheProgress.remove(video.key);
          _cacheProgressAt.remove(video.key);
          _cacheDone = i + 1;
        });
        SmartDialog.showToast(
          '缓存失败：${video.title}（${result.error ?? '未知错误'}）',
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _caching = false;
      _cacheProgress.clear();
      _cacheProgressAt.clear();
      _cacheTotal = 0;
      _cacheDone = 0;
      _status =
          '缓存完成：新增 $ok 条'
          '${skipped > 0 ? '，已有 $skipped 条' : ''}'
          '${ok + skipped == videos.length ? '' : '，失败 ${videos.length - ok - skipped} 条'}';
    });
    await _refreshCacheSize();
  }

  /// 单条缓存：已缓存就直接提示，避免重复下载。
  void _cacheOne(ShortVideo video) {
    if (_cachedKeys.contains(video.key)) {
      SmartDialog.showToast('已缓存到本地');
      return;
    }
    if (_caching) {
      SmartDialog.showToast('正在缓存中，请稍候');
      return;
    }
    unawaited(_cacheVideos([video]));
  }

  void _cacheSelected() {
    final targets = _localSelected;
    if (targets.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    _cacheVideos(targets);
  }

  static String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / 1024 / 1024;
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  }

  /// 插到「下一首播放」：正在播的 B 站 / 抖音队列播完这一条就接上它。
  void _queueNext(Iterable<ShortVideo> videos) {
    final entries = videos.map(QueueEntry.fromShortVideo);
    final added = QueueBus.addNext(entries);
    if (added == 0) {
      SmartDialog.showToast('这些已经在下一首队列里了');
      return;
    }
    SmartDialog.showToast('已加入下一首播放（待播 ${QueueBus.pending} 条）');
    setState(() {});
  }

  /// 加进「播放列表」（B 站 / 抖音 / TikTok 混在一起播的那份）。
  void _addToPlaylist(Iterable<ShortVideo> videos) {
    final list = videos.toList(growable: false);
    if (list.isEmpty) return;
    final added = ShortVideoPlaylistRepo.add(
      list.map(PlaylistItem.fromShortVideo),
    );
    if (added == 0) {
      SmartDialog.showToast('这些已经在播放列表里了');
      return;
    }
    ShortVideoAutoCache.schedule();
    final skipped = list.length - added;
    SmartDialog.showToast(
      skipped > 0 ? '已加入 $added 条，$skipped 条重复已跳过' : '已加入 $added 条',
    );
  }

  void _addSelectedToPlaylist() {
    final selected = _selectedVideos.toList(growable: false);
    if (selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    _addToPlaylist(selected);
  }

  void _queueSelectedNext() {
    final selected = _selectedVideos.toList(growable: false);
    if (selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    _queueNext(selected);
  }

  /// 把 Documents 里的诊断文件打成 zip，弹系统分享面板（隔空投送 / LocalSend）。
  Future<void> _exportDiagnostics() async {
    final path = await DiagProbe.exportAndShare();
    if (!mounted) return;
    SmartDialog.showToast(
      path == null ? '没有可导出的诊断文件' : '诊断包已生成：${path.split('/').last}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBody: true,
      appBar: AppBar(
        // 外层 MainLayout 已按状态栏高度给 body 补过 padding，
        // AppBar 若再 primary:true 会重复加一次安全区，顶部出现大片空白。
        primary: false,
        toolbarHeight: 44,
        title: _platformSwitcher(theme),
        titleSpacing: 16,
        actions: [
          _headIcon(
            tooltip: '播放列表',
            icon: const Icon(Icons.queue_music, size: 20),
            onTap: () => Get.to(() => const ShortVideoPlaylistPage()),
          ),
          _headIcon(
            tooltip: _syncing ? '同步中' : '同步',
            onTap: _syncing ? null : () => _sync(),
            icon: _syncing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync, size: 20),
          ),
          TextButton.icon(
            onPressed: _videos.isEmpty && !_selecting
                ? null
                : _toggleSelectMode,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: Badge(
              isLabelVisible: _selecting && _selectedCount > 0,
              label: Text(
                '$_selectedCount',
                style: const TextStyle(fontSize: 10),
              ),
              child: Icon(
                _selecting ? Icons.close : Icons.checklist,
                size: 18,
              ),
            ),
            label: Text(_selecting ? '退出多选' : '多选'),
          ),
          _moreMenu(theme),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_webLoggedOut)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 14,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '未登录，点右上角登录',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _statusBar(theme),
          Expanded(
            child: Builder(
              builder: (bodyContext) {
                // extendBody 下 Scaffold 会把底栏高度注入 body 的
                // MediaQuery.padding.bottom，列表尾部按它留白，
                // 否则最后一张卡片会被悬浮底栏盖住。
                final bottomInset = MediaQuery.paddingOf(bodyContext).bottom;
                return NotificationListener<ScrollNotification>(
                  onNotification: _onScrollNotification,
                  child: _videos.isEmpty
                      ? _empty(theme)
                      : Column(
                          children: [
                            _listHeader(theme),
                            Expanded(child: _list(theme, bottomInset)),
                          ],
                        ),
                );
              },
            ),
          ),
        ],
      ),
      // 底栏叠在 body 之上：上滑只把它向下平移，body 不跟着变形；
      // 底栏自己补系统安全区与主界面导航栏高度，按钮不会被底部导航栏盖住。
      bottomNavigationBar: _videos.isEmpty
          ? null
          : ValueListenableBuilder<double>(
              valueListenable: _barOffset,
              child: _bottomBar(theme),
              builder: (context, offset, child) => FractionalTranslation(
                translation: Offset(0, offset / _bottomBarHideOffset),
                child: child,
              ),
            ),
    );
  }

  Widget _headIcon({
    required String tooltip,
    required Widget icon,
    required VoidCallback? onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: icon,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
    );
  }

  /// 诊断、导出、清空这类低频操作收进更多菜单，顶栏只留图标。
  Widget _moreMenu(ThemeData theme) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_horiz),
      onSelected: (value) {
        switch (value) {
          case 'diagnose':
            Get.to(() => const RootScanPage());
          case 'export':
            _exportDiagnostics();
          case 'clear':
            _clear();
        }
      },
      itemBuilder: (context) => [
        _menuItem('diagnose', Icons.monitor_heart_outlined, '根因诊断'),
        if (kDiagEnabled) _menuItem('export', Icons.ios_share, '导出诊断包'),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'clear',
          enabled: _videos.isNotEmpty,
          child: _menuRow(
            Icons.delete_outline,
            '清空收藏',
            color: _videos.isEmpty ? null : theme.colorScheme.error,
          ),
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem<String>(
      value: value,
      child: _menuRow(icon, label),
    );
  }

  Widget _menuRow(IconData icon, String label, {Color? color}) {
    final tint = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 18, color: tint),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: tint)),
      ],
    );
  }

  /// 平台切换：标题行左侧的胶囊分段控件，当前平台用主题色高亮。
  Widget _platformSwitcher(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 8, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        // 右侧 actions 较多，窄屏或大字号时允许整体等比缩小，避免横向溢出。
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: SegmentedButton<ShortVideoPlatform>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: ShortVideoPlatform.douyin,
                label: Text('抖音'),
              ),
              ButtonSegment(
                value: ShortVideoPlatform.tiktok,
                label: Text('TikTok'),
              ),
            ],
            selected: {platform},
            onSelectionChanged: (selection) =>
                widget.onPlatformChanged(selection.first),
            style: SegmentedButton.styleFrom(
              minimumSize: const Size(72, 32),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              textStyle: theme.textTheme.labelMedium,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: scheme.surfaceContainerHighest,
              foregroundColor: scheme.onSurfaceVariant,
              selectedBackgroundColor: scheme.primaryContainer,
              selectedForegroundColor: scheme.onPrimaryContainer,
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 单行细状态条：同步、缓存、链接解析都走这里，不再塞进底部按钮区。
  Widget _statusBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    final busy = _syncing || _caching || _addingLink;
    final text = _status.trim().isEmpty ? '就绪' : _status.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 8, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            if (busy)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: scheme.primary,
                ),
              )
            else
              Icon(
                Icons.info_outline,
                size: 13,
                color: scheme.onSurfaceVariant,
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.2,
                ),
              ),
            ),
            if (_caching && _cacheTotal > 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  '$_cacheDone/$_cacheTotal',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (_cacheBytes > 0)
              TextButton(
                onPressed: _caching ? null : _clearCache,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  minimumSize: const Size(0, 22),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: Text(
                  '清缓存 ${_fmtBytes(_cacheBytes)}',
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _listHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
      child: Row(
        children: [
          Text(
            '本地 ${_videos.length} 条',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (_selecting && _selectedCount > 0) ...[
            const SizedBox(width: 8),
            Text(
              '已选 $_selectedCount',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.primary,
              ),
            ),
          ],
          const Spacer(),
          TextButton.icon(
            onPressed: _addingLink ? null : _addFromLink,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            icon: _addingLink
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.link, size: 14),
            label: const Text('粘贴链接'),
          ),
        ],
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    final scheme = theme.colorScheme;
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight = constraints.maxHeight > 32
            ? constraints.maxHeight - 32
            : 0.0;
        return SingleChildScrollView(
          // 主界面导航栏叠画在 body 之上，这里补足它的高度，保证
          // 快捷入口和底部说明都能滚到可见区域。
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            safeBottom + _mainBottomNavHeight + 16,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 128,
                      height: 116,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 104,
                            height: 104,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  scheme.primaryContainer,
                                  scheme.tertiaryContainer,
                                ],
                              ),
                            ),
                            child: Icon(
                              Icons.video_library_rounded,
                              size: 46,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 8,
                            child: Icon(
                              Icons.auto_awesome,
                              size: 20,
                              color: scheme.primary.withValues(alpha: 0.7),
                            ),
                          ),
                          Positioned(
                            bottom: 2,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
                              decoration: BoxDecoration(
                                color: scheme.surface,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: scheme.outlineVariant.withValues(
                                    alpha: 0.6,
                                  ),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.play_arrow_rounded,
                                    size: 16,
                                    color: scheme.primary,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    '收藏',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '还没有${platform.album}收藏',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '登录一次${platform.album}网页，之后就能增量拉取；'
                      '也可以直接粘贴单条分享链接。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _addingLink ? null : _addFromLink,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        icon: _addingLink
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.link_rounded, size: 20),
                        label: Text(
                          _addingLink ? '正在解析链接…' : '粘贴链接添加',
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _openingWeb ? null : _openWeb,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        icon: const Icon(Icons.public_rounded, size: 20),
                        label: const Text('打开网页抓取'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _openingWeb ? null : _directSync,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        icon: const Icon(Icons.sync_alt_rounded, size: 20),
                        label: const Text('直接同步（只拉新增）'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '网页打不开时，可在 Kumone 抓同一份收藏，'
                      '两台手机共用 WebDAV 后点右上角同步。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _list(ThemeData theme, double bottomInset) {
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(10, 0, 10, bottomInset + 6),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
        final checked = widget.selected.containsKey(video.key);
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: _selecting && checked
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
                : theme.colorScheme.surfaceContainerLow,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: _selecting && checked
                    ? theme.colorScheme.primary.withValues(alpha: 0.7)
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            child: InkWell(
              onTap: () => _selecting ? _toggleSelect(video) : _play(index),
              onLongPress: () {
                if (!_selecting) widget.onSelectingChanged(true);
                _toggleSelect(video);
              },
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _videoCover(theme, video, checked),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SizedBox(
                        height: 128,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              video.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              video.author.trim().isEmpty
                                  ? '未知作者'
                                  : video.author.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                height: 1.2,
                              ),
                            ),
                            const Spacer(),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer
                                        .withValues(alpha: 0.75),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    platform.album,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color:
                                          theme.colorScheme.onPrimaryContainer,
                                      fontWeight: FontWeight.w600,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  Icons.schedule_rounded,
                                  size: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 2),
                                Flexible(
                                  child: Text(
                                    video.durationText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    if (_selecting)
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: Icon(
                          checked
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: checked
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _cacheButton(theme, video),
                          SizedBox(
                            width: 36,
                            height: 36,
                            child: PopupMenuButton<String>(
                              tooltip: '更多',
                              padding: EdgeInsets.zero,
                              icon: const Icon(
                                Icons.more_vert_rounded,
                                size: 20,
                              ),
                              onSelected: (value) {
                                switch (value) {
                                  case 'play':
                                    _play(index);
                                  case 'next':
                                    _queueNext([video]);
                                  case 'playlist':
                                    _addToPlaylist([video]);
                                  case 'cache':
                                    _cacheOne(video);
                                  case 'delete':
                                    _deleteOne(video);
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'play',
                                  child: Text('播放'),
                                ),
                                const PopupMenuItem(
                                  value: 'next',
                                  child: Text('下一首播放'),
                                ),
                                const PopupMenuItem(
                                  value: 'playlist',
                                  child: Text('加入播放列表'),
                                ),
                                PopupMenuItem(
                                  value: 'cache',
                                  enabled: !_cachedKeys.contains(video.key),
                                  child: Text(
                                    _cachedKeys.contains(video.key)
                                        ? '已缓存'
                                        : '缓存到本地',
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除…'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 卡片右侧的缓存按钮：未缓存是下载图标，下载中显示环形进度，
  /// 已缓存变成对勾。比藏在「更多」菜单里更容易被发现。
  Widget _cacheButton(ThemeData theme, ShortVideo video) {
    final scheme = theme.colorScheme;
    final progress = _cacheProgress[video.key];
    final cached = _cachedKeys.contains(video.key);
    final Widget icon;
    if (progress != null) {
      icon = Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              value: progress > 0 ? progress : null,
              strokeWidth: 2.2,
              color: scheme.primary,
            ),
          ),
          Icon(Icons.download_rounded, size: 12, color: scheme.primary),
        ],
      );
    } else {
      icon = Icon(
        cached ? Icons.download_done_rounded : Icons.download_rounded,
        size: 21,
        color: cached ? scheme.primary : scheme.onSurfaceVariant,
      );
    }
    return IconButton(
      tooltip: cached ? '已缓存' : '缓存到本地',
      onPressed: progress != null ? null : () => _cacheOne(video),
      icon: icon,
      iconSize: 21,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    );
  }

  Widget _videoCover(ThemeData theme, ShortVideo video, bool checked) {
    final scheme = theme.colorScheme;
    final progress = _cacheProgress[video.key];
    Widget placeholder() => DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primaryContainer.withValues(alpha: 0.55),
            scheme.surfaceContainerHighest,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.movie_creation_outlined,
          size: 28,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 96,
        height: 128,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video.cover.isEmpty)
              placeholder()
            else
              Image.network(
                video.cover,
                fit: BoxFit.cover,
                cacheWidth: 260,
                errorBuilder: (_, _, _) => placeholder(),
              ),
            if (_selecting && checked)
              ColoredBox(
                color: scheme.primary.withValues(alpha: 0.14),
              ),
            if (_cachedKeys.contains(video.key))
              Positioned(
                left: 5,
                top: 5,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.download_done_rounded,
                        size: 10,
                        color: scheme.onPrimary,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '已缓存',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimary,
                          fontSize: 9,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (progress != null && progress < 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.black.withValues(alpha: 0.3),
                  color: scheme.primary,
                ),
              ),
            Positioned(
              right: 5,
              bottom: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  video.durationText,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontSize: 10,
                    height: 1.1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(ThemeData theme) {
    // 两个间距都要加，不是二选一。
    //
    // 外层 MainLayout 把 body 按整屏高度布局，底部导航栏是叠画在 body 之上的，
    // 不会挤压它。所以这里必须同时留出：
    //   1. 系统底部安全区（6S 上有 home indicator，viewPadding.bottom 不为 0）
    //   2. 主界面底部导航栏本身的高度
    //
    // 上一版写成了 `bottomInset > 0 ? bottomInset + 8 : 56`——6S 的
    // viewPadding.bottom 正好不为 0，于是走了第一个分支，只留了安全区，
    // 那 56px 的导航栏高度根本没留，按钮照样被压住。这就是用户说
    // 「底栏挡住了下面两个按钮」一直没修好的原因。
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    final localSelected = _localSelected;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        safeBottom + _mainBottomNavHeight + 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_linkNeedsLogin)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _openWeb,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
                icon: const Icon(Icons.open_in_browser, size: 16),
                label: const Text('打开网页登录后再试'),
              ),
            ),
          if (_selecting)
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  onPressed: _videos.isEmpty ? null : _selectAll,
                  icon: const Icon(Icons.select_all),
                  label: Text(_allLocalSelected ? '取消全选' : '全选'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _selectedCount == 0 ? null : _playSelected,
                  icon: const Icon(Icons.playlist_play),
                  label: Text('播放所选 $_selectedCount 条'),
                ),
                FilledButton.icon(
                  onPressed: localSelected.isEmpty || _caching
                      ? null
                      : _cacheSelected,
                  icon: _caching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_for_offline_outlined),
                  label: Text(
                    _caching && _cacheTotal > 0
                        ? '缓存中 $_cacheDone/$_cacheTotal'
                        : '缓存所选 ${localSelected.length} 条',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: localSelected.isEmpty ? null : _deleteSelected,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: Text('删除所选 ${localSelected.length} 条'),
                ),
                OutlinedButton.icon(
                  onPressed: _selectedCount == 0 ? null : _queueSelectedNext,
                  icon: const Icon(Icons.queue_play_next),
                  label: Text('下一首 $_selectedCount 条'),
                ),
                OutlinedButton.icon(
                  onPressed: _selectedCount == 0
                      ? null
                      : _addSelectedToPlaylist,
                  icon: const Icon(Icons.playlist_add),
                  label: Text('加入列表 $_selectedCount 条'),
                ),
              ],
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _openWeb,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size.fromHeight(38),
                    ),
                    icon: const Icon(Icons.public, size: 18),
                    label: const Text('打开网页 / 抓取'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _videos.isEmpty ? null : _playAll,
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('全部播放'),
                ),
              ],
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _openingWeb ? null : _directSync,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  icon: const Icon(Icons.sync_alt, size: 16),
                  label: const Text('直接同步（只拉新增）'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
// findstr-anchor (GBK bytes, do not re-encode): 粘贴链接
// findstr-anchor (GBK bytes, do not re-encode): 导出诊断
