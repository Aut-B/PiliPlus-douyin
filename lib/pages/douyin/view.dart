import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 抖音 / TikTok 收藏列表。
///
/// 抓取本身在 [ShortVideoWebPage] 里做（网页登录 + 旁观接口返回），这里只负责
/// 展示、播放和 WebDAV 同步。
class ShortVideoFavoritesPage extends StatefulWidget {
  const ShortVideoFavoritesPage({super.key, required this.platform});

  final ShortVideoPlatform platform;

  @override
  State<ShortVideoFavoritesPage> createState() => _ShortVideoFavoritesPageState();
}

class _ShortVideoFavoritesPageState extends State<ShortVideoFavoritesPage> {
  final List<ShortVideo> _videos = [];
  bool _syncing = false;
  String _status = '';

  ShortVideoPlatform get platform => widget.platform;

  @override
  void initState() {
    super.initState();
    _reload();
    _status = _videos.isEmpty
        ? '还没有抓取到收藏，点下面「打开网页」登录后抓取'
        : '本地 ${_videos.length} 条';
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSync());
  }

  void _reload() {
    final stored = ShortVideoRepo.load(platform);
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
      final count = await ShortVideoSync.synchronize();
      _reload();
      if (!mounted) return;
      setState(() => _status = '已同步，共 $count 条');
      if (!silent) SmartDialog.showToast('同步完成，共 $count 条');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '同步失败：$e');
      if (!silent) SmartDialog.showToast('同步失败: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _openWeb() async {
    await Get.to(() => ShortVideoWebPage(platform: platform));
    _reload();
    if (!mounted) return;
    setState(() => _status = '本地 ${_videos.length} 条');
    await _sync(silent: true);
  }

  void _play(int index) {
    if (_videos.isEmpty) return;
    Get.to(() => ShortVideoPlayerPage(videos: List.of(_videos), index: index));
  }

  void _playAll() => _play(0);

  void _clear() {
    setState(() {
      _videos.clear();
      _status = '已清空，可重新抓取';
    });
    ShortVideoRepo.save(platform, const []);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(platform.title),
        actions: [
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
            tooltip: '全部播放',
            onPressed: _videos.isEmpty ? null : _playAll,
            icon: const Icon(Icons.play_arrow),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _videos.isEmpty ? _empty(theme) : _list(theme),
          ),
          _bottomBar(theme),
        ],
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
        return ListTile(
          onTap: () => _play(index),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 48,
              height: 64,
              child: video.cover.isEmpty
                  ? Container(color: theme.dividerColor.withValues(alpha: 0.1))
                  : Image.network(
                      video.cover,
                      fit: BoxFit.cover,
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
          trailing: const Icon(Icons.play_circle_outline),
        );
      },
    );
  }

  Widget _bottomBar(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
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
      ),
    );
  }
}