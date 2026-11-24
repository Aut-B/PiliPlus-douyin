import 'dart:async' show unawaited;

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
import 'package:flutter/services.dart' show Clipboard;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final platform in <ShortVideoPlatform>[
              ShortVideoPlatform.douyin,
              ShortVideoPlatform.tiktok,
            ])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: TextButton(
                  onPressed: () {
                    setState(() => _platform = platform);
                  },
                  style: TextButton.styleFrom(
                    minimumSize: const Size(64, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    backgroundColor: _platform == platform
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null,
                  ),
                  child: Text(platform.album),
                ),
              ),
          ],
        ),
      ),
      // 换平台就换一份 State，避免两个平台的列表状态互相污染。
      body: ShortVideoFavoritesPage(
        key: ValueKey(_platform.id),
        platform: _platform,
        selecting: _selecting,
        selected: _selected,
        onSelectingChanged: _setSelecting,
        onToggleSelect: _toggleSelect,
        onToggleAll: _toggleAll,
        onRemoveSelected: _removeSelected,
      ),
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
    required this.selecting,
    required this.selected,
    required this.onSelectingChanged,
    required this.onToggleSelect,
    required this.onToggleAll,
    required this.onRemoveSelected,
  });

  final ShortVideoPlatform platform;
  final bool selecting;
  final Map<String, ShortVideo> selected;
  final ValueChanged<bool> onSelectingChanged;
  final ValueChanged<ShortVideo> onToggleSelect;
  final ValueChanged<Iterable<ShortVideo>> onToggleAll;
  final ValueChanged<Iterable<ShortVideo>> onRemoveSelected;

  @override
  State<ShortVideoFavoritesPage> createState() => _ShortVideoFavoritesPageState();
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
    _reload();
    _refreshCacheSize();
    _status = _videos.isEmpty
        ? '还没有抓取到收藏，点下面「打开网页」登录后抓取'
        : '本地 ${_videos.length} 条';
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSync());
  }

  void _reload() {
    final stored = ShortVideoRepo.load(platform);
    if (!mounted) return;
    setState(() {
      _videos
        ..clear()
        ..addAll(stored);
    });
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
        text = '同步到 ${result.total} 条，但${platform.album}一条都没有（${result.summary}）';
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
          () => _status = '收到 $_rawCount 段数据，无新增'
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
        () => _status = '新增 ${added.length} 条，跳过 ${result.skipped} 条，'
            '本地 ${_videos.length} 条',
      );
    }
  }

  /// 正在从分享链接解析并加入一条收藏。
  bool _addingLink = false;

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

  void _linkFailed(String message) {
    if (!mounted) return;
    setState(() => _status = message);
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
    setState(() => _addingLink = true);
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
          _linkFailed('没识别到视频 id，请粘贴完整分享链接');
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
      final playUrl = await ShortVideoWeb.resolvePlayUrl(
        platformId: target.id,
        videoId: link.videoId,
        userAgent: target.mobileUserAgent,
      );
      if (!mounted) return;
      if (playUrl == null || playUrl.isEmpty) {
        _linkFailed('没拿到可播放直链，请稍后再试');
        return;
      }
      final video = ShortVideo(
        id: link.videoId,
        platform: target.id,
        desc: '分享链接添加的视频',
        author: '',
        cover: '',
        durationMs: 0,
        playUrl: playUrl,
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

  /// 删一条：本地列表 + 删除墓碑 + 本地缓存文件。
  Future<void> _deleteOne(ShortVideo video) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('删除这条收藏？'),
      content: Text(
        '${video.title}\n\n'
        '只删本机这一条；如果它还在播放列表里，本地视频文件会保留；'
        '下次同步时远端那份也会被排除。',
      ),
    );
    if (!confirmed || !mounted) return;
    final position = _videos.indexWhere((e) => e.key == video.key);
    setState(() {
      _videos.removeWhere((e) => e.key == video.key);
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
    final confirmed = await showConfirmDialog(
      context: context,
      title: Text('删除所选的 ${targets.length} 条？'),
      content: const Text(
        '播放列表里还留着的条目会保留本地视频文件，'
        '下次同步时远端那份也会被排除。',
      ),
    );
    if (!confirmed || !mounted) return;
    final positions = <int>[
      for (final video in targets)
        _videos.indexWhere((e) => e.key == video.key),
    ];
    setState(() {
      _videos.removeWhere((e) => targets.any((t) => t.key == e.key));
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
        final at = (i < positions.length ? positions[i] : _videos.length)
            .clamp(0, _videos.length);
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
    setState(() => _caching = true);
    var ok = 0;
    var skipped = 0;
    final failures = <String>[];
    final cookie = await ShortVideoWeb.cookieHeader(
      platform.cookieDomainNeedle,
    );
    for (var i = 0; i < videos.length; i++) {
      if (!mounted) break;
      final video = videos[i];
      final existing = await ShortVideoMediaCache.localPath(video);
      if (existing != null) {
        skipped++;
        continue;
      }
      setState(
        () => _status = '缓存中 ${i + 1}/${videos.length}：${video.title}',
      );
      final urls = <String>[
        if (video.playUrl.isNotEmpty) video.playUrl,
        ...stableUrls(video),
      ];
      final result = await ShortVideoMediaCache.download(
        video,
        urls: urls,
        userAgent: platform.userAgent,
        referer: platform.referer,
        cookie: cookie,
        appUserAgent: platform == ShortVideoPlatform.tiktok
            ? tiktokAppUserAgent
            : '',
      );
      if (result.ok) {
        ok++;
      } else {
        failures.add('${video.title}（${result.error}）');
      }
    }
    if (!mounted) return;
    setState(() {
      _caching = false;
      _status = '缓存完成：新增 $ok 条'
          '${skipped > 0 ? '，已有 $skipped 条' : ''}'
          '${failures.isEmpty ? '' : '，失败 ${failures.length} 条'}';
    });
    await _refreshCacheSize();
    if (failures.isNotEmpty) {
      SmartDialog.showToast('失败：${failures.first}');
    }
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

  /// 状态信息按句分行，避免长句和缓存按钮挤在同一行。
  Iterable<String> get _statusLines {
    final lines = _status
        .split(RegExp(r'[；;\n]'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return lines.isEmpty ? const ['就绪'] : lines;
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
      appBar: AppBar(
        title: Text(
          platform.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        titleSpacing: 12,
        actions: [
          // 根因诊断入口。放在最前面，用户随时能打开看结论并截屏。
          _headAction(
            label: '诊断',
            icon: const Icon(Icons.monitor_heart_outlined, size: 20),
            onTap: () => Get.to(() => const RootScanPage()),
          ),
          if (kDiagEnabled)
            _headAction(
              label: '导出诊断',
              icon: const Icon(Icons.ios_share, size: 20),
              onTap: _exportDiagnostics,
            ),
          _headAction(
            label: '列表',
            icon: const Icon(Icons.queue_music, size: 20),
            onTap: () => Get.to(() => const ShortVideoPlaylistPage()),
          ),
          // 管理类操作和上面的「查看」分开，避免一排图标挤在一起分不清。
          Container(
            width: 1,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
          _headAction(
            label: '同步',
            onTap: _syncing ? null : () => _sync(),
            icon: _syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync, size: 20),
          ),
          _headAction(
            label: '清空',
            icon: const Icon(Icons.delete_outline, size: 20),
            onTap: _videos.isEmpty ? null : _clear,
          ),
          _headAction(
            label: _selecting ? '退出' : '多选',
            onTap: _videos.isEmpty && !_selecting
                ? null
                : _toggleSelectMode,
            icon: Badge(
              isLabelVisible: _selecting && _selectedCount > 0,
              label: Text('$_selectedCount', style: const TextStyle(fontSize: 10)),
              child: Icon(
                _selecting ? Icons.close : Icons.checklist,
                size: 20,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_webLoggedOut)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '未登录，点右上角登录',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '从 App 复制分享链接，免登录只加这一条',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _addingLink ? null : _addFromLink,
                  icon: _addingLink
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link, size: 18),
                  label: const Text('粘贴链接添加'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _videos.isEmpty ? _empty(theme) : _list(theme),
          ),
        ],
      ),
      // 底栏原来放在 Column 里。问题在于主界面用 MainLayout 布局：body 按
      // 整屏高度布局（bodyConstraints = 全高），底部导航栏是**叠画在 body
      // 之上**的，不是挤压。所以 body 里最后那排按钮正好被底栏盖住，点不到。
      // 放进 bottomNavigationBar 由 Scaffold 自己避让；同时因为 body 被
      // 撑满整屏，Scaffold 算出来的 bottom padding 不可靠，_bottomBar 里
      // 再按 MediaQuery.viewPadding 显式补一份。
      bottomNavigationBar: _bottomBar(theme),
    );
  }

  /// 顶部操作：图标下面带文字，单独看一个图标也知道是干什么的。
  ///
  /// 保留 tooltip 是为了读屏和长按提示，但不再依赖它——用户第一眼要能
  /// 看到「诊断 / 列表 / 同步 / 清空 / 多选」。
  Widget _headAction({
    required String label,
    required Widget icon,
    required VoidCallback? onTap,
  }) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Opacity(
          opacity: onTap == null ? 0.38 : 1,
          child: SizedBox(
            width: 42,
            height: 48,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 22,
                  height: 22,
                  child: Center(child: icon),
                ),
                const SizedBox(height: 1),
                Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 10, height: 1.1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有收藏',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '点下面「打开网页」，在网页里登录 ${platform.album}，'
              '然后点「开始抓取」，抓完回来自动带过来。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '已经登录过就直接点「直接同步（只拉新增）」，'
              '只解析新收藏，旧条目不再重复处理。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '不想登录网页：把视频分享链接粘贴到上方「粘贴链接添加」，'
              '只加这一条。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '网页打不开也不要紧：在 Kumone 里抓同一份收藏，'
              '两台手机配同一个 WebDAV，这里点右上角同步就行。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(ThemeData theme) {
    return ListView.builder(
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final video = _videos[index];
        final checked = widget.selected.containsKey(video.key);
        return ListTile(
          onTap: () => _selecting ? _toggleSelect(video) : _play(index),
          onLongPress: () {
            if (!_selecting) widget.onSelectingChanged(true);
            _toggleSelect(video);
          },
          selected: _selecting && checked,
          leading: _selecting
              ? Icon(
                  checked
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: checked ? theme.colorScheme.primary : null,
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 48,
                    height: 64,
                    child: video.cover.isEmpty
                        ? Container(
                            color: theme.dividerColor.withValues(alpha: 0.1),
                          )
                        : Image.network(
                            video.cover,
                            fit: BoxFit.cover,
                            cacheWidth: 180,
                            errorBuilder: (_, _, _) => Container(
                              color: theme.dividerColor.withValues(alpha: 0.1),
                            ),
                          ),
                  ),
                ),
          title: Text(
            video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${video.author.isEmpty ? platform.album : video.author} · ${video.durationText}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'play':
                  _play(index);
                case 'next':
                  _queueNext([video]);
                case 'playlist':
                  _addToPlaylist([video]);
                case 'cache':
                  _cacheVideos([video]);
                case 'delete':
                  _deleteOne(video);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'play', child: Text('播放')),
              PopupMenuItem(value: 'next', child: Text('下一首播放')),
              PopupMenuItem(value: 'playlist', child: Text('加入播放列表')),
              PopupMenuItem(value: 'cache', child: Text('缓存到本地')),
              PopupMenuItem(value: 'delete', child: Text('删除（含缓存）')),
            ],
          ),
        );
      },
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
        16,
        8,
        16,
        safeBottom + _mainBottomNavHeight + 4,
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 同步结果里常有「已同步：…；本页 N 条」两段信息。原来和缓存
            // 按钮挤在同一个 Row 里，窄屏上被压成一坨；现在一段一行。
            for (final line in _statusLines)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  line,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (_cacheBytes > 0 || _selecting)
              Row(
                children: [
                  if (_selecting)
                    Text(
                      '已选 $_selectedCount 条',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  const Spacer(),
                  if (_cacheBytes > 0)
                    TextButton(
                      onPressed: _caching ? null : _clearCache,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: Text(
                        '缓存 ${_fmtBytes(_cacheBytes)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            if (_selecting)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _videos.isEmpty ? null : _selectAll,
                    icon: const Icon(Icons.select_all),
                    label: Text(_allLocalSelected ? '取消全选' : '全选'),
                  ),
                  FilledButton.icon(
                    onPressed: _selectedCount == 0 ? null : _playSelected,
                    icon: const Icon(Icons.playlist_play),
                    label: Text('播放所选 $_selectedCount 条'),
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
                  OutlinedButton.icon(
                    onPressed: localSelected.isEmpty || _caching
                        ? null
                        : _cacheSelected,
                    icon: const Icon(Icons.download_for_offline_outlined),
                    label: Text('缓存 ${localSelected.length} 条'),
                  ),
                  OutlinedButton.icon(
                    onPressed: localSelected.isEmpty ? null : _deleteSelected,
                    icon: const Icon(Icons.delete_outline),
                    label: Text('删除 ${localSelected.length} 条'),
                  ),
                ],
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _openWeb,
                      icon: const Icon(Icons.public),
                      label: const Text('打开网页 / 抓取'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _videos.isEmpty ? null : _playAll,
                    child: const Text('全部播放'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openingWeb ? null : _directSync,
                  icon: const Icon(Icons.sync_alt),
                  label: const Text('直接同步（只拉新增）'),
                ),
              ),
            ],
          ],
        ),
    );
  }
}
// findstr-anchor (GBK bytes, do not re-encode): 粘贴链接
// findstr-anchor (GBK bytes, do not re-encode): 导出诊断
