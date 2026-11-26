import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// 播放列表里一条属于哪个来源。列表本身不关心怎么取流，
/// 由各来源自己解析（B 站走 DASH，抖音 / TikTok 走网页直链或本地缓存）。
enum PlaylistSource {
  bili('bili', 'B站'),
  douyin('douyin', '抖音'),
  tiktok('tiktok', 'TikTok');

  const PlaylistSource(this.id, this.label);

  final String id;
  final String label;
}

/// 播放列表里的一条。
///
/// B 站收藏和抖音 / TikTok 收藏以前各播各的，这里把两种条目放在同一个列表里，
/// 顺序由用户决定——这才是「互通」。
class PlaylistItem {
  const PlaylistItem({
    required this.type,
    required this.title,
    required this.author,
    required this.cover,
    required this.durationMs,
    this.short,
    this.bvid,
    this.cid,
  });

  factory PlaylistItem.fromShortVideo(ShortVideo video) => PlaylistItem(
    type: 'short',
    title: video.title,
    author: video.author,
    cover: video.cover,
    durationMs: video.durationMs,
    short: video,
  );

  factory PlaylistItem.fromBili({
    required String bvid,
    required String title,
    required String author,
    required String cover,
    required int durationMs,
    int? cid,
  }) => PlaylistItem(
    type: 'bili',
    title: title,
    author: author,
    cover: cover,
    durationMs: durationMs,
    bvid: bvid,
    cid: cid,
  );

  /// 从播放队列的一条转过来（播放页「存为播放列表」用）。
  static PlaylistItem? fromEntry(QueueEntry entry) {
    if (entry.isBili) {
      final bvid = entry.bvid;
      if (bvid == null || bvid.isEmpty) return null;
      return PlaylistItem.fromBili(
        bvid: bvid,
        title: entry.title,
        author: entry.author,
        cover: entry.cover,
        durationMs: entry.durationMs,
        cid: entry.cid,
      );
    }
    final video = entry.short;
    if (video == null) return null;
    return PlaylistItem.fromShortVideo(video);
  }

  static PlaylistItem? fromJson(Map<String, dynamic> json) {
    final type = '${json['type'] ?? ''}';
    try {
      if (type == 'short') {
        final raw = json['short'];
        if (raw is! Map) return null;
        return PlaylistItem.fromShortVideo(
          ShortVideo.fromJson(raw.cast<String, dynamic>()),
        );
      }
      if (type == 'bili') {
        final bvid = '${json['bvid'] ?? ''}';
        if (bvid.isEmpty) return null;
        return PlaylistItem(
          type: 'bili',
          title: '${json['title'] ?? '视频'}',
          author: '${json['author'] ?? ''}',
          cover: '${json['cover'] ?? ''}',
          durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
          bvid: bvid,
          cid: (json['cid'] as num?)?.toInt(),
        );
      }
    } catch (_) {}
    return null;
  }

  final String type;
  final String title;
  final String author;
  final String cover;
  final int durationMs;

  /// 抖音 / TikTok 的原始条目（含直链和 videoId，跨设备也能重新解析）。
  final ShortVideo? short;
  final String? bvid;

  /// B 站视频的 cid。收藏接口直接带回 `ugc.first_cid`，有了它就不必在
  /// 播放前再打一次 videoIntro；老数据没有 cid 时解析侧会自己回查。
  final int? cid;

  bool get isBili => type == 'bili';

  PlaylistSource get source {
    if (isBili) return PlaylistSource.bili;
    return short?.platform == 'tiktok'
        ? PlaylistSource.tiktok
        : PlaylistSource.douyin;
  }

  /// 来源内的原始 id：B 站是 bvid，抖音 / TikTok 是站点视频 id。
  String get id => isBili ? (bvid ?? '') : (short?.id ?? '');

  /// 平台标签。
  String get platformLabel {
    return source.label;
  }

  String get key => isBili ? 'bili:$bvid' : 'short:${short?.key ?? ''}';

  String get durationText {
    if (durationMs <= 0) return '--:--';
    final total = durationMs ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  QueueEntry? toEntry() {
    if (isBili) {
      final id = bvid;
      if (id == null || id.isEmpty) return null;
      return QueueEntry.fromBili(
        bvid: id,
        title: title,
        author: author,
        cover: cover,
        durationMs: durationMs,
        cid: cid,
      );
    }
    final video = short;
    if (video == null) return null;
    return QueueEntry.fromShortVideo(video);
  }

  /// 按自己的来源解析出可直接开播的地址。播放列表 / 队列不关心来源差异，
  /// 切换下一条时只调用这一入口。
  Future<QueueMedia?> resolveStream({String cookie = ''}) async {
    final entry = toEntry();
    if (entry == null) return null;
    return resolveQueueEntry(entry, cookie: cookie);
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    if (short != null) 'short': short!.toJson(),
    if (bvid != null) 'bvid': bvid,
    if (cid != null) 'cid': cid,
    'title': title,
    'author': author,
    'cover': cover,
    'durationMs': durationMs,
  };
}

/// 播放列表的本地存储。B 站 / 抖音 / TikTok 混在一份里。
abstract final class ShortVideoPlaylistRepo {
  static const String _key = 'shortVideoPlaylist';

  static void Function()? onChanged;

  static void _notifyChanged() {
    final callback = onChanged;
    if (callback != null) callback();
  }

  static List<PlaylistItem> load() {
    try {
      final Object? raw = GStorage.localCache.get(_key, defaultValue: '');
      if (raw is! String || raw.isEmpty) return [];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final items = <PlaylistItem>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final item = PlaylistItem.fromJson(entry.cast<String, dynamic>());
        if (item != null) items.add(item);
      }
      return items;
    } catch (_) {
      return [];
    }
  }

  static void save(List<PlaylistItem> items) {
    try {
      GStorage.localCache.put(
        _key,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// 追加，去重（同一条已经在列表里就跳过）。返回新增条数；
  /// 只补全了 cid 的旧条目也计 1，避免调用方误报「已经在列表里」。
  static int add(Iterable<PlaylistItem> items) {
    final current = load();
    final indexByKey = <String, int>{
      for (var i = 0; i < current.length; i++) current[i].key: i,
    };
    var added = 0;
    var upgraded = 0;
    for (final item in items) {
      final at = indexByKey[item.key];
      if (at != null) {
        // 旧版本存的 B 站条目没有 cid；再次加入同一条时把 cid 补上，
        // 别让「已经加过了」把新拿到的 cid 永远挡在门外。
        final existing = current[at];
        if (existing.isBili && existing.cid == null && item.cid != null) {
          current[at] = PlaylistItem(
            type: existing.type,
            title: existing.title,
            author: existing.author,
            cover: existing.cover,
            durationMs: existing.durationMs,
            bvid: existing.bvid,
            cid: item.cid,
          );
          upgraded++;
        }
        continue;
      }
      indexByKey[item.key] = current.length;
      current.add(item);
      added++;
    }
    if (added > 0 || upgraded > 0) {
      save(current);
      _notifyChanged();
    }
    return added + upgraded;
  }

  static void remove(String key) {
    final current = load()..removeWhere((e) => e.key == key);
    save(current);
    _notifyChanged();
  }

  /// 按原位置插回去（删除后的「撤销」用）。
  static void insertAt(int index, PlaylistItem item) {
    final current = load()..removeWhere((e) => e.key == item.key);
    final at = index.clamp(0, current.length);
    current.insert(at, item);
    save(current);
    _notifyChanged();
  }

  /// 这份列表里有没有这一条。
  static bool contains(String key) => load().any((e) => e.key == key);

  static void clear() {
    save([]);
    _notifyChanged();
  }

  static int get length => load().length;
}

/// 播放列表页：看、删、清空、整张开播。
class ShortVideoPlaylistPage extends StatefulWidget {
  const ShortVideoPlaylistPage({
    super.key,
    this.currentKey,
    this.onPlay,
    this.onReorder,
  });

  /// 当前正在播的条目 key，用来高亮。
  final String? currentKey;

  /// 在播放页里打开时，点条目把整份列表交回播放页；为空则自己开播放页。
  final void Function(List<QueueEntry> entries, int index)? onPlay;

  /// 调序后把新顺序交回播放页，让播放队列跟着变。
  final void Function(List<PlaylistItem> items)? onReorder;

  @override
  State<ShortVideoPlaylistPage> createState() => _ShortVideoPlaylistPageState();
}

class _ShortVideoPlaylistPageState extends State<ShortVideoPlaylistPage> {
  List<PlaylistItem> _items = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    if (!mounted) return;
    setState(() => _items = ShortVideoPlaylistRepo.load());
  }

  void _play(int index) {
    final entries = <QueueEntry>[];
    var start = 0;
    for (var i = 0; i < _items.length; i++) {
      final entry = _items[i].toEntry();
      if (entry == null) continue;
      if (i < index) start++;
      entries.add(entry);
    }
    if (entries.isEmpty) {
      SmartDialog.showToast('列表里没有可播放的条目');
      return;
    }
    final at = start.clamp(0, entries.length - 1);
    final onPlay = widget.onPlay;
    if (onPlay != null) {
      onPlay(entries, at);
      Navigator.of(context).maybePop();
      return;
    }
    unawaited(
      openShortVideoQueue(entries, at, replaceCurrent: true),
    );
  }

  void _remove(PlaylistItem item) {
    ShortVideoPlaylistRepo.remove(item.key);
    _reload();
  }

  /// 拖动调序。顺序就是播放顺序，所以这里直接改存储。
  void _move(int from, int to) {
    if (from < 0 || from >= _items.length) return;
    if (to < 0 || to >= _items.length) return;
    final next = List<PlaylistItem>.of(_items);
    final item = next.removeAt(from);
    next.insert(to, item);
    ShortVideoPlaylistRepo.save(next);
    ShortVideoPlaylistRepo.onChanged?.call();
    setState(() => _items = next);
    widget.onReorder?.call(next);
  }

  Future<void> _clear() async {
    if (_items.isEmpty) return;
    ShortVideoPlaylistRepo.clear();
    _reload();
    SmartDialog.showToast('已清空播放列表');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('播放列表 ${_items.length}'),
        actions: [
          IconButton(
            tooltip: '清空',
            onPressed: _items.isEmpty ? null : _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _items.isEmpty
          ? _empty(theme)
          : ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: _items.length,
              onReorderItem: _move,
              itemBuilder: (context, index) {
                final item = _items[index];
                final isCurrent = item.key == widget.currentKey;
                return ListTile(
                  key: ValueKey(item.key),
                  onTap: () => _play(index),
                  selected: isCurrent,
                  selectedTileColor: theme.colorScheme.primary.withValues(
                    alpha: 0.12,
                  ),
                  leading: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 48,
                          height: 64,
                          child: item.cover.isEmpty
                              ? Container(
                                  color: theme.dividerColor.withValues(
                                    alpha: 0.1,
                                  ),
                                )
                              : Image.network(
                                  item.cover,
                                  fit: BoxFit.cover,
                                  cacheWidth: 180,
                                  errorBuilder: (_, _, _) => Container(
                                    color: theme.dividerColor.withValues(
                                      alpha: 0.1,
                                    ),
                                  ),
                                ),
                          ),
                        ),
                      if (isCurrent)
                        const Positioned(
                          right: 2,
                          bottom: 2,
                          child: Icon(
                            Icons.play_circle_fill,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                    ],
                  ),
                  title: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${isCurrent ? '正在播放 · ' : ''}'
                    '${item.platformLabel} · ${item.durationText}'
                    '${item.author.isEmpty ? '' : ' · ${item.author}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 8,
                          ),
                          child: Icon(Icons.drag_handle, size: 20),
                        ),
                      ),
                      IconButton(
                        tooltip: '移出播放列表',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        onPressed: () => _remove(item),
                        icon: const Icon(Icons.remove_circle_outline, size: 18),
                      ),
                    ],
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _items.isEmpty ? null : () => _play(0),
            icon: const Icon(Icons.play_arrow),
            label: Text('播放全部 ${_items.length} 条'),
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
              Icons.queue_music,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('播放列表还是空的', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              'B 站收藏、抖音收藏、TikTok 收藏里都能「加入播放列表」，'
              '加进来的条目按这里的顺序连着播。',
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
}
