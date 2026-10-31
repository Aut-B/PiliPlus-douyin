import 'dart:convert';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// 本地缓存 + WebDAV 同步。
///
/// 远端只有一个文件（`<目录>/ShortVideo/shortvideo.json`），抖音和 TikTok 都在
/// 里面，Kumone 与 PiliPlus 也共用同一份格式——一台手机抓到的收藏，另一台
/// 打开就能看到。
abstract final class ShortVideoRepo {
  static String _cacheKey(ShortVideoPlatform platform) =>
      'shortVideoFavorites_${platform.id}';

  static List<ShortVideo> load(ShortVideoPlatform platform) {
    try {
      final raw = GStorage.localCache.get(_cacheKey(platform), defaultValue: '');
      if (raw is! String || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => ShortVideo.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static void save(ShortVideoPlatform platform, List<ShortVideo> videos) {
    try {
      GStorage.localCache.put(
        _cacheKey(platform),
        jsonEncode(videos.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  static List<ShortVideo> loadAll() => [
    for (final platform in ShortVideoPlatform.values) ...load(platform),
  ];

  static void saveAll(List<ShortVideo> all) {
    for (final platform in ShortVideoPlatform.values) {
      save(
        platform,
        all.where((e) => e.platform == platform.id).toList(),
      );
    }
  }
}

abstract final class ShortVideoSync {
  static bool get configured =>
      Pref.webdavUri.trim().isNotEmpty &&
      Pref.webdavUsername.isNotEmpty &&
      Pref.webdavPassword.isNotEmpty;

  static String get remotePath {
    var dir = Pref.webdavDirectory.trim();
    if (dir.isEmpty) dir = '/';
    if (!dir.startsWith('/')) dir = '/$dir';
    if (!dir.endsWith('/')) dir = '$dir/';
    return '${dir}ShortVideo/shortvideo.json';
  }

  static Future<webdav.Client> _client() async {
    final client =
        webdav.newClient(
            Pref.webdavUri,
            user: Pref.webdavUsername,
            password: Pref.webdavPassword,
          )
          ..setHeaders({'accept-charset': 'utf-8'})
          ..setConnectTimeout(12000)
          ..setReceiveTimeout(12000)
          ..setSendTimeout(12000);
    final path = remotePath;
    final dir = path.substring(0, path.lastIndexOf('/'));
    await client.mkdirAll(dir);
    return client;
  }

  /// 远端还没有文件时返回 null（不是错误）。
  static Future<ShortVideoSyncDocument?> pull() async {
    if (!configured) return null;
    final client = await _client();
    try {
      final data = await client.read(remotePath);
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is Map) {
        return ShortVideoSyncDocument.fromJson(decoded.cast<String, dynamic>());
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> push(ShortVideoSyncDocument document) async {
    if (!configured) return;
    final client = await _client();
    await client.write(remotePath, utf8.encode(jsonEncode(document.toJson())));
  }

  /// 本地 + 远端取并集，写回本地，再把合并结果推上去。
  /// 返回合并后的总条数。
  static Future<int> synchronize() async {
    if (!configured) return 0;
    final remote = await pull();
    final merged = mergeShortVideos(
      ShortVideoRepo.loadAll(),
      remote?.items ?? const [],
    );
    ShortVideoRepo.saveAll(merged);
    await push(
      ShortVideoSyncDocument(
        updatedAt: DateTime.now().millisecondsSinceEpoch.toDouble(),
        items: merged,
      ),
    );
    return merged.length;
  }
}