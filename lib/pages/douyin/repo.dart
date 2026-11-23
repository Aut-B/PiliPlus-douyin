import 'dart:convert';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:webdav_client/webdav_client.dart' as webdav;

/// 本地缓存 + WebDAV 同步。
///
/// 远端有快照（`shortvideo.json`）与增量（`shortvideo_delta.json`）两个文件，
/// 抖音和 TikTok 都在里面，Kumone 与 PiliPlus 也共用同一份快照格式——一台手机
/// 抓到的收藏，另一台打开就能看到。日常同步只写增量，不再重写整份快照。
abstract final class ShortVideoRepo {
  static String _cacheKey(ShortVideoPlatform platform) =>
      'shortVideoFavorites_${platform.id}';

  static String _syncedKey(ShortVideoPlatform platform) =>
      'shortVideoSynced_${platform.id}';

  static List<ShortVideo> load(ShortVideoPlatform platform) {
    final Object? raw;
    try {
      raw = GStorage.localCache.get(_cacheKey(platform), defaultValue: '');
    } catch (_) {
      return const [];
    }
    if (raw is! String || raw.isEmpty) return const [];

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];

    // 逐条解析：以前一条坏数据会让整份缓存变成空列表，
    // 表现就是「明明同步了 16 条，点进去一条都没有」。
    final result = <ShortVideo>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      try {
        final video = ShortVideo.fromJson(entry.cast<String, dynamic>());
        if (video.platform == platform.id && video.id.isNotEmpty) {
          result.add(video);
        }
      } catch (_) {}
    }
    return result;
  }

  /// 写入本地缓存，返回「写完能读回来几条」。返回 -1 表示写入本身失败。
  static int save(ShortVideoPlatform platform, List<ShortVideo> videos) {
    try {
      GStorage.localCache.put(
        _cacheKey(platform),
        jsonEncode(videos.map((e) => e.toJson()).toList()),
      );
      // 已同步集合与收藏列表同源：每落库一次就同步刷新，抓取时只读 key
      // 判重，不用再把整份列表解码一遍。
      GStorage.localCache.put(
        _syncedKey(platform),
        jsonEncode(videos.map((e) => e.key).toList()),
      );
    } catch (_) {
      return -1;
    }
    return load(platform).length;
  }

  /// 该平台已落库的 `platform:id` 集合。
  ///
  /// 旧版本没有这份键时回退到收藏列表，自动完成迁移。
  static Set<String> loadSynced(ShortVideoPlatform platform) {
    try {
      final Object? raw = GStorage.localCache.get(
        _syncedKey(platform),
        defaultValue: '',
      );
      if (raw is String && raw.isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List) return decoded.whereType<String>().toSet();
      }
    } catch (_) {}
    return load(platform).map((e) => e.key).toSet();
  }

  static List<ShortVideo> loadAll() => [
    for (final platform in ShortVideoPlatform.values) ...load(platform),
  ];

  // MARK: - 删除墓碑
  //
  // 同步是「本地 + 远端取并集」，删掉的条目下一次同步就会从远端回来。
  // 所以删一条要留个墓碑，合并时按墓碑过滤，再把过滤后的结果推上去。

  static String _deletedKey(ShortVideoPlatform platform) =>
      'shortVideoDeleted_${platform.id}';

  static Set<String> loadDeleted(ShortVideoPlatform platform) {
    try {
      final Object? raw = GStorage.localCache.get(
        _deletedKey(platform),
        defaultValue: '',
      );
      if (raw is! String || raw.isEmpty) return <String>{};
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toSet();
      }
    } catch (_) {}
    return <String>{};
  }

  static Set<String> loadAllDeleted() => {
    for (final platform in ShortVideoPlatform.values)
      ...loadDeleted(platform),
  };

  static void markDeleted(ShortVideoPlatform platform, Iterable<String> keys) {
    final deleted = loadDeleted(platform)..addAll(keys);
    try {
      GStorage.localCache.put(
        _deletedKey(platform),
        jsonEncode(deleted.toList()),
      );
    } catch (_) {}
  }

  /// 重新抓到了这条：墓碑撤掉，让它重新进列表。
  static void unmarkDeleted(ShortVideoPlatform platform, Iterable<String> keys) {
    final deleted = loadDeleted(platform)..removeAll(keys);
    try {
      GStorage.localCache.put(
        _deletedKey(platform),
        jsonEncode(deleted.toList()),
      );
    } catch (_) {}
  }

  /// 按平台分桶写回，返回每个平台实际落库的条数。
  static Map<String, int> saveAll(List<ShortVideo> all) {
    final written = <String, int>{};
    for (final platform in ShortVideoPlatform.values) {
      written[platform.id] = save(
        platform,
        all.where((e) => e.platform == platform.id).toList(),
      );
    }
    return written;
  }
}

/// 远端增量文件：只存「新增」和「删除」，没变化的条目一个字节都不重复推。
///
/// `adds` / `deletes` 都以 `platform:id` 为键，且同一个 key 不会同时出现在
/// 两边——写增量时加新增会抹掉同 key 的删除，反之亦然。
class ShortVideoDelta {
  const ShortVideoDelta({
    this.version = 1,
    this.updatedAt = 0,
    this.adds = const {},
    this.deletes = const {},
  });

  final int version;
  final double updatedAt;
  final Map<String, ShortVideo> adds;
  final Map<String, double> deletes;

  int get opCount => adds.length + deletes.length;

  Map<String, dynamic> toJson() => {
    'version': version,
    'updatedAt': updatedAt,
    'adds': {for (final e in adds.entries) e.key: e.value.toJson()},
    'deletes': deletes,
  };

  factory ShortVideoDelta.fromJson(Map<String, dynamic> json) {
    final adds = <String, ShortVideo>{};
    final rawAdds = json['adds'];
    if (rawAdds is Map) {
      for (final entry in rawAdds.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        try {
          final video = ShortVideo.fromJson(value.cast<String, dynamic>());
          if (video.id.isNotEmpty) adds[video.key] = video;
        } catch (_) {}
      }
    }

    final deletes = <String, double>{};
    final rawDeletes = json['deletes'];
    if (rawDeletes is Map) {
      for (final entry in rawDeletes.entries) {
        final value = entry.value;
        deletes['${entry.key}'] = value is num
            ? value.toDouble()
            : double.tryParse('$value') ?? 0;
      }
    } else if (rawDeletes is List) {
      // 兼容只有 key 列表、没有时间的写法。
      for (final key in rawDeletes) {
        deletes['$key'] = 0;
      }
    }

    return ShortVideoDelta(
      version: (json['version'] as num?)?.toInt() ?? 1,
      updatedAt: (json['updatedAt'] as num?)?.toDouble() ?? 0,
      adds: adds,
      deletes: deletes,
    );
  }
}

/// 远端快照 + 增量合并后的当前视图。
class ShortVideoRemoteState {
  const ShortVideoRemoteState({
    this.snapshot,
    this.delta,
    required this.items,
  });

  final ShortVideoSyncDocument? snapshot;
  final ShortVideoDelta? delta;
  final List<ShortVideo> items;

  Set<String> get keys => {for (final video in items) video.key};
}

/// 一次同步的结果。分开报抖音 / TikTok，远端文件里到底有几条、本地又落库了
/// 几条也一并说出来——之前只报「共 N 条」，远端读失败、落库失败都照样显示
/// 成功，人还以为同步好了。
class ShortVideoSyncResult {
  const ShortVideoSyncResult({
    required this.douyin,
    required this.tiktok,
    required this.remote,
    this.storedDouyin = -1,
    this.storedTiktok = -1,
    this.added = 0,
    this.skipped = 0,
    this.deleted = 0,
    this.parsed = 0,
    this.pushed = false,
  });

  final int douyin;
  final int tiktok;

  /// 远端文件里的条数；-1 表示远端还没有这个文件。
  final int remote;

  /// 本地缓存写完读回来的条数；-1 表示写入失败。
  final int storedDouyin;
  final int storedTiktok;

  /// 这一轮新增到本地列表的条数。
  final int added;

  /// 已经在本地 / 已同步集合里、直接跳过的条数。
  final int skipped;

  /// 这一轮实际推送 / 应用的删除操作数。
  final int deleted;

  /// 这一轮真正进入逐条字段解析的条数（纯 WebDAV 同步恒为 0）。
  final int parsed;

  /// 这一轮有没有真的写远端。false 代表远端已是最新，直接跳过。
  final bool pushed;

  int get total => douyin + tiktok;

  bool get storedOk =>
      storedDouyin == douyin && storedTiktok == tiktok;

  /// 固定格式，便于日志里直接 grep「只处理新增」。
  String get counts =>
      'new=$added skipped=$skipped deleted=$deleted parsed=$parsed';

  String get summary {
    final remoteText = remote < 0 ? '远端无文件' : '远端 $remote 条';
    if (storedOk) {
      if (!pushed) {
        return '抖音 $douyin / TikTok $tiktok（$remoteText，已是最新）';
      }
      return '抖音 $douyin / TikTok $tiktok（$remoteText，新增 $added 条）';
    }
    final storedText = storedDouyin < 0 || storedTiktok < 0
        ? '本地写入失败'
        : '本地只存下 抖音 $storedDouyin / TikTok $storedTiktok';
    return '抖音 $douyin / TikTok $tiktok（$remoteText，$storedText）';
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

  /// 增量文件与快照同目录，只放本次及历史未压缩的 add / delete。
  static String get deltaPath {
    final path = remotePath;
    return '${path.substring(0, path.lastIndexOf('/') + 1)}'
        'shortvideo_delta.json';
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
  ///
  /// 其它错误要抛出来：以前这里把所有异常都吞掉当成「远端没文件」，
  /// 结果远端读失败也照样显示「已同步共 N 条」，人还以为同步成功了。
  static Future<ShortVideoSyncDocument?> pullSnapshot() async {
    if (!configured) return null;
    final client = await _client();
    try {
      final data = await client.read(remotePath);
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is Map) {
        return ShortVideoSyncDocument.fromJson(decoded.cast<String, dynamic>());
      }
      throw Exception('$remotePath 不是预期的 JSON 对象');
    } catch (e) {
      if (e is Exception && e.toString().contains('不是预期的')) rethrow;
      final text = e.toString();
      if (text.contains('404') || text.contains('Not Found')) return null;
      throw Exception('读取 $remotePath 失败：$text');
    }
  }

  static Future<ShortVideoDelta?> pullDelta() async {
    if (!configured) return null;
    final client = await _client();
    final path = deltaPath;
    try {
      final data = await client.read(path);
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is Map) {
        return ShortVideoDelta.fromJson(decoded.cast<String, dynamic>());
      }
      throw Exception('$path 不是预期的 JSON 对象');
    } catch (e) {
      if (e is Exception && e.toString().contains('不是预期的')) rethrow;
      final text = e.toString();
      final lower = text.toLowerCase();
      if (lower.contains('404') ||
          lower.contains('not found') ||
          lower.contains('nosuchkey') ||
          text.contains('不存在')) {
        return null;
      }
      throw Exception('读取 $path 失败：$text');
    }
  }

  static Future<void> pushSnapshot(ShortVideoSyncDocument document) async {
    if (!configured) return;
    final client = await _client();
    await client.write(remotePath, utf8.encode(jsonEncode(document.toJson())));
  }

  static Future<void> pushDelta(ShortVideoDelta delta) async {
    if (!configured) return;
    final client = await _client();
    await client.write(deltaPath, utf8.encode(jsonEncode(delta.toJson())));
  }

  /// 读快照 + 增量，合并出「远端当前视图」。
  ///
  /// 删除按时间戳判新旧：删除时间不早于条目更新时间才生效，避免把别的设备
  /// 刚刚更新的条目误删。add 与 delete 同时存在时以较晚的操作为准。
  static Future<ShortVideoRemoteState> pullState() async {
    final snapshot = await pullSnapshot();
    final delta = await pullDelta();
    final byKey = <String, ShortVideo>{
      for (final video in snapshot?.items ?? const <ShortVideo>[]) video.key: video,
    };
    if (delta != null) {
      for (final entry in delta.adds.entries) {
        final existing = byKey[entry.key];
        if (existing == null || entry.value.updatedAt >= existing.updatedAt) {
          byKey[entry.key] = entry.value;
        }
      }
      for (final entry in delta.deletes.entries) {
        final existing = byKey[entry.key];
        if (existing == null) continue;
        if (entry.value >= existing.updatedAt) byKey.remove(entry.key);
      }
    }
    return ShortVideoRemoteState(
      snapshot: snapshot,
      delta: delta,
      items: byKey.values.toList(),
    );
  }

  /// 本地 + 远端取并集，只把新增 / 删除写进增量文件。
  ///
  /// 以前每次同步都无条件 push 整份 JSON：收藏几百条时，热路径每次都得重写
  /// 远端整个文件，表现就是「每次同步都把整个收藏夹重新收藏一遍」。现在：
  ///
  /// * 本地有、远端视图没有（或本地更新）的 key → delta `adds`；
  /// * 墓碑里、远端视图还存在的 key → delta `deletes`；
  /// * 没有变更就完全不碰远端；
  /// * 只有首次接入（远端连快照都没有）或增量累积超过 [compactThreshold]
  ///   时才写一次完整快照并清空增量，作为基线 / 压缩。
  static Future<ShortVideoSyncResult> synchronize() async {
    if (!configured) {
      return const ShortVideoSyncResult(douyin: 0, tiktok: 0, remote: -1);
    }

    final remote = await pullState();
    final local = ShortVideoRepo.loadAll();
    var deleted = ShortVideoRepo.loadAllDeleted();

    // 别的设备删掉的条目，本地也跟随删除并补墓碑：否则下一轮又会被本地
    // 并回来，双方来回推同一条。只有远端删除时间不早于本地更新时间才跟随。
    final remoteDeletes = remote.delta?.deletes ?? const <String, double>{};
    final followed = <String>[];
    for (final video in local) {
      if (deleted.contains(video.key)) continue;
      final at = remoteDeletes[video.key];
      if (at != null && at >= video.updatedAt) followed.add(video.key);
    }
    if (followed.isNotEmpty) {
      for (final platform in ShortVideoPlatform.values) {
        final keys = followed.where((e) => e.startsWith('${platform.id}:'));
        if (keys.isNotEmpty) ShortVideoRepo.markDeleted(platform, keys);
      }
      deleted = {...deleted, ...followed};
    }

    final localActive = local
        .where((e) => !deleted.contains(e.key))
        .toList(growable: false);
    final remoteActive = remote.items
        .where((e) => !deleted.contains(e.key))
        .toList(growable: false);
    final merged = mergeShortVideos(localActive, remoteActive);
    // 没有新增 / 删除 / 更新的旧条目时不再整份重写本地缓存：抓取和同步都
    // 只处理变化项。首次接入或从别的设备拉到新条目时 merged 才会不同。
    final localChanged = !_sameVideos(local, merged);
    final written = localChanged
        ? ShortVideoRepo.saveAll(merged)
        : {
            for (final platform in ShortVideoPlatform.values)
              platform.id: merged
                  .where((e) => e.platform == platform.id)
                  .length,
          };

    final localKeys = localActive.map((e) => e.key).toSet();
    final remoteByKey = <String, ShortVideo>{
      for (final video in remote.items) video.key: video,
    };
    final adds = <String, ShortVideo>{};
    for (final video in localActive) {
      final existing = remoteByKey[video.key];
      if (existing == null || video.updatedAt > existing.updatedAt) {
        adds[video.key] = video;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch.toDouble();
    final deletes = <String, double>{
      for (final key in deleted)
        if (remoteByKey.containsKey(key)) key: now,
    };

    final existingDelta = remote.delta ?? const ShortVideoDelta();
    final deltaAdds = Map<String, ShortVideo>.of(existingDelta.adds);
    final deltaDeletes = Map<String, double>.of(existingDelta.deletes);
    for (final entry in adds.entries) {
      deltaAdds[entry.key] = entry.value;
      deltaDeletes.remove(entry.key);
    }
    for (final entry in deletes.entries) {
      deltaDeletes[entry.key] = entry.value;
      deltaAdds.remove(entry.key);
    }
    final nextDelta = ShortVideoDelta(
      updatedAt: now,
      adds: deltaAdds,
      deletes: deltaDeletes,
    );

    final added = merged.where((e) => !localKeys.contains(e.key)).length;
    final skipped = merged.length - added;
    // 远端只有 delta、没有快照（快照被删或第一次由本机之外写入）时补一次
    // 基线，否则只认快照的 Kumone / 旧版会一条都看不到。
    final needBaseline = remote.snapshot == null && merged.isNotEmpty;
    var pushed = false;
    if (adds.isNotEmpty || deletes.isNotEmpty || needBaseline) {
      if (needBaseline || nextDelta.opCount > compactThreshold) {
        await pushSnapshot(
          ShortVideoSyncDocument(updatedAt: now, items: merged),
        );
        await pushDelta(ShortVideoDelta(updatedAt: now));
      } else {
        await pushDelta(nextDelta);
      }
      pushed = true;
    }

    final result = ShortVideoSyncResult(
      douyin: merged.where((e) => e.platform == 'douyin').length,
      tiktok: merged.where((e) => e.platform == 'tiktok').length,
      remote: remote.items.length,
      storedDouyin: written['douyin'] ?? -1,
      storedTiktok: written['tiktok'] ?? -1,
      added: added,
      skipped: skipped,
      deleted: deletes.length,
      pushed: pushed,
    );
    debugPrint(
      '[fav-sync] webdav ${result.counts} remote=${result.remote} '
      'pushed=$pushed',
    );
    return result;
  }

  /// 增量累积到这么多操作时压缩成快照（写快照 + 清空增量）。
  static const int compactThreshold = 400;

  /// 本地缓存是否已经就是合并后的结果（用于跳过无意义的整份重写）。
  static bool _sameVideos(List<ShortVideo> a, List<ShortVideo> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.key != y.key ||
          x.desc != y.desc ||
          x.author != y.author ||
          x.cover != y.cover ||
          x.durationMs != y.durationMs ||
          x.playUrl != y.playUrl ||
          x.videoId != y.videoId ||
          x.updatedAt != y.updatedAt) {
        return false;
      }
    }
    return true;
  }
}
