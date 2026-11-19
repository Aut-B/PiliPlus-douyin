import 'dart:async' show unawaited;

import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/pages/douyin/auto_cache.dart';
import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/playlist.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:PiliPlus/pages/douyin/rootscan_view.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
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
      ),
    );
  }
}

/// 抖音 / TikTok 收藏列表。
///
/// 抓取本身在原生 WKWebView 里做（网页登录 + 旁观接口返回），这里只负责
/// 展示、播放和 WebDAV 同步。
class ShortVideoFavoritesPage extends StatefulWidget {
  const ShortVideoFavoritesPage({super.key, required this.platform});

  final ShortVideoPlatform platform;

  @override
  State<ShortVideoFavoritesPage> createState() => _ShortVideoFavoritesPageState();
}

class _ShortVideoFavoritesPageState extends State<ShortVideoFavoritesPage> {
  /// 主界面底部导航栏的高度。它叠画在本页 body 之上，不吃布局，
  /// 所以本页自己要留出这段高度，否则最后一行按钮会被压住点不到。
  static const double _mainBottomNavHeight = 56;

  final List<ShortVideo> _videos = [];
  bool _syncing = false;
  String _status = '';

  /// 原生一共回传了多少段响应（不等于视频条数）。
  int _rawCount = 0;

  /// 多选：全选 / 播放所选。
  bool _selecting = false;
  final Set<String> _selected = {};

  /// 正在把选中的条目下到本地。
  bool _caching = false;

  /// 本地缓存目录占用（字节）。
  int _cacheBytes = 0;

  ShortVideoPlatform get platform => widget.platform;

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
      var text = '已同步：${result.summary}';
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

  Future<void> _openWeb() async {
    _rawCount = 0;
    ShortVideoWeb.onPayload = _ingest;
    ShortVideoWeb.onStatus = (text) {
      if (mounted) setState(() => _status = text);
    };
    ShortVideoWeb.onClosed = () {
      if (!mounted) return;
      _reload();
      setState(() => _status = '本地 ${_videos.length} 条');
      ShortVideoAutoCache.schedule();
      _sync(silent: true);
    };
    try {
      // 把本地已有条数带下去：抓够这么多就不再无限滚动翻旧数据。
      await ShortVideoWeb.open(platform, knownCount: _videos.length);
    } catch (e) {
      if (mounted) setState(() => _status = '打开网页失败：$e');
      SmartDialog.showToast('打开网页失败: $e');
    }
  }

  void _ingest(String body) {
    _rawCount++;
    final parsed = ShortVideoParser.fromResponseBody(body, platform);
    if (parsed.isEmpty) {
      if (mounted) {
        setState(
          () => _status = '收到 $_rawCount 段数据，解析出 0 条（字段可能变了）',
        );
      }
      return;
    }

    final indexById = <String, int>{
      for (var i = 0; i < _videos.length; i++) _videos[i].id: i,
    };
    var changed = 0;
    for (final video in parsed) {
      final index = indexById[video.id];
      if (index != null) {
        // 直链是签名过的，会过期；重抓时用新的覆盖旧的。
        if (_videos[index].playUrl != video.playUrl) {
          _videos[index] = video;
          changed++;
        }
      } else {
        _videos.add(video);
        indexById[video.id] = _videos.length - 1;
        changed++;
      }
    }
    if (changed == 0) return;
    // 重新抓到了就撤掉删除墓碑，让它重新回到列表。
    ShortVideoRepo.unmarkDeleted(platform, parsed.map((e) => e.key));
    ShortVideoRepo.save(platform, _videos);
    // 抓到的每一条同时归档进「播放列表」。那是另一份存储：删收藏、清空收藏
    // 都不会动它，误删之后还能从播放列表里接着听/看，不用重新登录抓一遍。
    final archived = ShortVideoPlaylistRepo.add(
      parsed.map(PlaylistItem.fromShortVideo),
    );
    ShortVideoAutoCache.schedule();
    if (mounted) {
      setState(
        () => _status = '已抓取 ${_videos.length} 条'
            '${archived > 0 ? '，播放列表 +$archived' : ''}',
      );
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

  /// 只播选中的这些（顺序按列表顺序）。
  void _playSelected() {
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    final queue = _videos.where((e) => _selected.contains(e.key)).toList();
    if (queue.isEmpty) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    unawaited(_openQueue(queue.map(QueueEntry.fromShortVideo).toList(), 0));
  }

  void _toggleSelect(ShortVideo video) {
    setState(() {
      if (!_selected.remove(video.key)) _selected.add(video.key);
    });
  }

  void _toggleSelectMode() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  void _selectAll() {
    setState(() {
      if (_selected.length == _videos.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_videos.map((e) => e.key));
      }
    });
  }

  void _playAll() => _play(0);

  Future<void> _clear() async {
    final keys = _videos.map((e) => e.key).toList();
    final videos = List<ShortVideo>.of(_videos);
    final positions = List<int>.generate(videos.length, (i) => i);
    setState(() {
      _videos.clear();
      _selected.clear();
      _selecting = false;
      _status = '已清空，可重新抓取';
    });
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
      _selected.remove(video.key);
      _status = '已删除 1 条，本地 ${_videos.length} 条';
    });
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
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    final targets = _videos.where((e) => _selected.contains(e.key)).toList();
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
      _videos.removeWhere((e) => _selected.contains(e.key));
      _status = '已删除 ${targets.length} 条，本地 ${_videos.length} 条';
      _selected.clear();
      _selecting = false;
    });
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
    setState(() {
      for (var i = 0; i < removed.length; i++) {
        final video = removed[i];
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
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    _cacheVideos(_videos.where((e) => _selected.contains(e.key)).toList());
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
    final added = ShortVideoPlaylistRepo.add(
      videos.map(PlaylistItem.fromShortVideo),
    );
    if (added == 0) {
      SmartDialog.showToast('这些已经在播放列表里了');
      return;
    }
    ShortVideoAutoCache.schedule();
    SmartDialog.showToast(
      '已加入播放列表（共 ${ShortVideoPlaylistRepo.length} 条）',
    );
  }

  void _addSelectedToPlaylist() {
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    _addToPlaylist(_videos.where((e) => _selected.contains(e.key)));
  }

  void _queueSelectedNext() {
    if (_selected.isEmpty) {
      SmartDialog.showToast('先选几条');
      return;
    }
    _queueNext(_videos.where((e) => _selected.contains(e.key)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(platform.title),
        actions: [
          // 根因诊断入口。放在最前面，用户随时能打开看结论并截屏。
          IconButton(
            tooltip: '根因诊断',
            onPressed: () => Get.to(() => const RootScanPage()),
            icon: const Icon(Icons.monitor_heart_outlined),
          ),
          IconButton(
            tooltip: '播放列表',
            onPressed: () => Get.to(() => const ShortVideoPlaylistPage()),
            icon: const Icon(Icons.queue_music),
          ),
          IconButton(
            tooltip: 'WebDAV 同步',
            onPressed: _syncing ? null : () => _sync(),
            icon: _syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: _videos.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: _selecting ? '退出多选' : '多选',
            onPressed: _videos.isEmpty ? null : _toggleSelectMode,
            icon: Icon(_selecting ? Icons.close : Icons.checklist),
          ),
          IconButton(
            tooltip: '全部播放',
            onPressed: _videos.isEmpty ? null : _playAll,
            icon: const Icon(Icons.play_arrow),
          ),
        ],
      ),
      body: _videos.isEmpty ? _empty(theme) : _list(theme),
      // 底栏原来放在 Column 里。问题在于主界面用 MainLayout 布局：body 按
      // 整屏高度布局（bodyConstraints = 全高），底部导航栏是**叠画在 body
      // 之上**的，不是挤压。所以 body 里最后那排按钮正好被底栏盖住，点不到。
      // 放进 bottomNavigationBar 由 Scaffold 自己避让；同时因为 body 被
      // 撑满整屏，Scaffold 算出来的 bottom padding 不可靠，_bottomBar 里
      // 再按 MediaQuery.viewPadding 显式补一份。
      bottomNavigationBar: _bottomBar(theme),
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
        final checked = _selected.contains(video.key);
        return ListTile(
          onTap: () => _selecting ? _toggleSelect(video) : _play(index),
          onLongPress: () {
            if (!_selecting) setState(() => _selecting = true);
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
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, safeBottom + _mainBottomNavHeight),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _status,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
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
                    label: Text(
                      _selected.length == _videos.length && _videos.isNotEmpty
                          ? '取消全选'
                          : '全选',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _playSelected,
                    icon: const Icon(Icons.playlist_play),
                    label: Text('播放所选 ${_selected.length} 条'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _selected.isEmpty ? null : _queueSelectedNext,
                    icon: const Icon(Icons.queue_play_next),
                    label: Text('下一首 ${_selected.length} 条'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _selected.isEmpty
                        ? null
                        : _addSelectedToPlaylist,
                    icon: const Icon(Icons.playlist_add),
                    label: Text('加入列表 ${_selected.length} 条'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _selected.isEmpty || _caching
                        ? null
                        : _cacheSelected,
                    icon: const Icon(Icons.download_for_offline_outlined),
                    label: Text('缓存 ${_selected.length} 条'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _selected.isEmpty ? null : _deleteSelected,
                    icon: const Icon(Icons.delete_outline),
                    label: Text('删除 ${_selected.length} 条'),
                  ),
                ],
              )
            else
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
          ],
        ),
    );
  }
}
