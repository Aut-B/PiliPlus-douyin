import 'dart:convert';

/// 抖音 / TikTok 共用的平台描述。
///
/// 两个站的网页版结构几乎一样：React 前端 + 需要签名的 JSON 接口。抓取、
/// 解析、播放共用一套代码，只在这里区分 URL、UA 和字段名。
enum ShortVideoPlatform {
  douyin(
    id: 'douyin',
    title: '抖音收藏',
    album: '抖音',
    homeUrl: 'https://www.douyin.com/user/self?showTab=favorite_collection',
    referer: 'https://www.douyin.com/',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/131.0.0.0 Safari/537.36',
    tabTitles: ['收藏', '收藏夹'],
    markers: ['aweme_list', 'aweme_detail'],
  ),
  tiktok(
    id: 'tiktok',
    title: 'TikTok 收藏',
    album: 'TikTok',
    homeUrl: 'https://www.tiktok.com/@me',
    referer: 'https://www.tiktok.com/',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) '
        'Version/17.4 Safari/605.1.15',
    tabTitles: ['收藏', 'Favorites', 'Favorite'],
    markers: ['itemList', 'itemStruct', 'item_list'],
  );

  const ShortVideoPlatform({
    required this.id,
    required this.title,
    required this.album,
    required this.homeUrl,
    required this.referer,
    required this.userAgent,
    required this.tabTitles,
    required this.markers,
  });

  final String id;
  final String title;
  final String album;
  final String homeUrl;
  final String referer;
  final String userAgent;
  final List<String> tabTitles;

  /// 响应体里出现这些键才值得回传。
  final List<String> markers;

  String get siteUrl => album == '抖音'
      ? 'https://www.douyin.com/'
      : 'https://www.tiktok.com/';

  String shareUrl(String videoId) => id == 'douyin'
      ? 'https://www.douyin.com/video/$videoId'
      : 'https://www.tiktok.com/@i/video/$videoId';

  static ShortVideoPlatform? fromId(String? value) {
    for (final platform in values) {
      if (platform.id == value) return platform;
    }
    return null;
  }
}

/// 一条短视频。字段名与 WebDAV 同步用的 JSON 一一对应，Kumone 和 PiliPlus
/// 读写同一个远端文件。
class ShortVideo {
  const ShortVideo({
    required this.id,
    required this.platform,
    required this.desc,
    required this.author,
    required this.cover,
    required this.durationMs,
    required this.playUrl,
    this.updatedAt = 0,
  });

  final String id;
  final String platform;
  final String desc;
  final String author;
  final String cover;
  final int durationMs;
  final String playUrl;
  final double updatedAt;

  /// 跨 App 的唯一键（不同平台的数字 id 会撞）。
  String get key => '$platform:$id';

  String get title => desc.trim().isEmpty ? '短视频' : desc.trim();

  String get durationText {
    if (durationMs <= 0) return '--:--';
    final total = durationMs ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  ShortVideo copyWith({String? playUrl, double? updatedAt}) => ShortVideo(
    id: id,
    platform: platform,
    desc: desc,
    author: author,
    cover: cover,
    durationMs: durationMs,
    playUrl: playUrl ?? this.playUrl,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'platform': platform,
    'desc': desc,
    'author': author,
    'cover': cover,
    'durationMS': durationMs,
    'playURL': playUrl,
    'updatedAt': updatedAt,
  };

  factory ShortVideo.fromJson(Map<String, dynamic> json) => ShortVideo(
    id: '${json['id'] ?? ''}',
    platform: '${json['platform'] ?? 'douyin'}',
    desc: '${json['desc'] ?? ''}',
    author: '${json['author'] ?? ''}',
    cover: '${json['cover'] ?? ''}',
    durationMs: (json['durationMS'] as num?)?.toInt() ?? 0,
    playUrl: '${json['playURL'] ?? ''}',
    updatedAt: (json['updatedAt'] as num?)?.toDouble() ?? 0,
  );
}

abstract final class ShortVideoParser {

  /// 解析网页里截获的一段 JSON。
  ///
  /// 抖音是 `aweme_list` / `aweme_detail`，TikTok 是 `itemList` / `itemStruct`；
  /// `video` 字段名也不同（`play_addr` vs `playAddr`），`duration` 一个是
  /// 毫秒一个是秒。
  static List<ShortVideo> fromResponseBody(
    String body,
    ShortVideoPlatform platform,
  ) {
    if (body.length < 40) return const [];
    if (!platform.markers.any(body.contains)) return const [];
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      return fromJsonObject(decoded.cast<String, dynamic>(), platform);
    } catch (_) {
      return const [];
    }
  }

  static List<ShortVideo> fromJsonObject(
    Map<String, dynamic> root,
    ShortVideoPlatform platform,
  ) {
    for (final key in const [
      'aweme_list',
      'itemList',
      'item_list',
      'awemeList',
    ]) {
      final list = root[key];
      if (list is List) {
        return list
            .whereType<Map>()
            .map((e) => _fromItem(e.cast<String, dynamic>(), platform))
            .whereType<ShortVideo>()
            .toList();
      }
    }
    for (final key in const ['aweme_detail', 'itemStruct', 'itemInfo']) {
      final detail = root[key];
      if (detail is Map) {
        final video = _fromItem(detail.cast<String, dynamic>(), platform);
        if (video != null) return [video];
      }
    }
    return const [];
  }

  static ShortVideo? _fromItem(
    Map<String, dynamic> item,
    ShortVideoPlatform platform,
  ) {
    final id = '${item['aweme_id'] ?? item['id'] ?? ''}';
    if (id.isEmpty) return null;
    final video = item['video'];
    if (video is! Map) return null;
    final videoMap = video.cast<String, dynamic>();

    String? playUrl;
    var durationMs = 0;
    var cover = '';

    switch (platform) {
      case ShortVideoPlatform.douyin:
        playUrl = _firstUrl(videoMap, const [
          'play_addr_h264',
          'play_addr',
          'download_addr',
        ]);
        durationMs = _int(videoMap['duration']) ?? 0;
        cover =
            _firstUrl(videoMap, const [
              'cover',
              'origin_cover',
              'dynamic_cover',
            ]) ??
            '';
      case ShortVideoPlatform.tiktok:
        playUrl = _tiktokPlayUrl(videoMap);
        // TikTok 的 duration 是秒。
        durationMs = (_int(videoMap['duration']) ?? 0) * 1000;
        cover =
            _string(videoMap['cover']) ??
            _string(videoMap['originCover']) ??
            _firstUrl(videoMap, const ['cover', 'origin_cover']) ??
            '';
    }

    if (playUrl == null || playUrl.isEmpty) return null;

    final author = item['author'];
    return ShortVideo(
      id: id,
      platform: platform.id,
      desc: _string(item['desc']) ?? '',
      author: author is Map
          ? (_string(author['nickname']) ?? _string(author['uniqueId']) ?? '')
          : '',
      cover: cover,
      durationMs: durationMs,
      playUrl: playUrl,
      updatedAt: DateTime.now().millisecondsSinceEpoch.toDouble(),
    );
  }

  static String? _tiktokPlayUrl(Map<String, dynamic> video) {
    final direct = _string(video['playAddr']);
    if (direct != null && direct.isNotEmpty) return direct;
    final download = _string(video['downloadAddr']);
    if (download != null && download.isNotEmpty) return download;
    final bitrates = video['bitrateInfo'];
    if (bitrates is List) {
      for (final entry in bitrates) {
        if (entry is Map) {
          final play = entry['PlayAddr'];
          if (play is Map) {
            final urls = play['UrlList'];
            if (urls is List) {
              for (final url in urls) {
                if (url is String && url.isNotEmpty) return url;
              }
            }
          }
        }
      }
    }
    return _firstUrl(video, const ['play_addr', 'download_addr']);
  }

  static String? _firstUrl(Map<String, dynamic> container, List<String> keys) {
    for (final key in keys) {
      final entry = container[key];
      if (entry is! Map) continue;
      final urls = entry['url_list'];
      if (urls is! List) continue;
      for (final url in urls) {
        if (url is String && url.isNotEmpty) return url;
      }
    }
    return null;
  }

  static String? _string(Object? value) {
    if (value is String) return value;
    if (value is num) return value.toString();
    return null;
  }

  static int? _int(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// 两个 App 共用的远端文件格式。
class ShortVideoSyncDocument {
  const ShortVideoSyncDocument({
    this.version = 1,
    this.updatedAt = 0,
    this.items = const [],
  });

  final int version;
  final double updatedAt;
  final List<ShortVideo> items;

  Map<String, dynamic> toJson() => {
    'version': version,
    'updatedAt': updatedAt,
    'items': items.map((e) => e.toJson()).toList(),
  };

  factory ShortVideoSyncDocument.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    return ShortVideoSyncDocument(
      version: (json['version'] as num?)?.toInt() ?? 1,
      updatedAt: (json['updatedAt'] as num?)?.toDouble() ?? 0,
      items: raw is List
          ? raw
                .whereType<Map>()
                .map((e) => ShortVideo.fromJson(e.cast<String, dynamic>()))
                .toList()
          : const [],
    );
  }
}

/// 按 `platform:id` 取并集；同一条以 `updatedAt` 更新的为准。
/// 胜出的那条如果播放直链是空的，用另一条的直链补上。
List<ShortVideo> mergeShortVideos(
  List<ShortVideo> local,
  List<ShortVideo> remote,
) {
  final order = <String>[];
  final byKey = <String, ShortVideo>{};

  for (final video in [...local, ...remote]) {
    final key = video.key;
    final existing = byKey[key];
    if (existing == null) {
      byKey[key] = video;
      order.add(key);
      continue;
    }
    final winner = video.updatedAt > existing.updatedAt ? video : existing;
    var playUrl = winner.playUrl;
    if (playUrl.isEmpty) playUrl = existing.playUrl;
    if (playUrl.isEmpty) playUrl = video.playUrl;
    byKey[key] = winner.copyWith(playUrl: playUrl);
  }

  return order.map((key) => byKey[key]!).toList();
}