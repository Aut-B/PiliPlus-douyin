import 'dart:async' show Timer, unawaited;
import 'dart:io' show File;

import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/playlist.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:PiliPlus/pages/douyin/web.dart';

/// 播放列表 / 正在播的后台落盘器。
///
/// 签名直链会过期，TikTok 尤其容易隔天就 403；只有本地文件才算「随时能播的
/// 收藏」。这里串行把播放列表和最近起播的条目补下到持久目录，不阻塞收藏页
/// 刷新。收藏夹本身不再全量预下载——6S 只有 16G，收藏越多越会吃光磁盘。
abstract final class ShortVideoAutoCache {
  static bool _running = false;
  static bool _pending = false;
  static Timer? _retryTimer;

  /// 每条失败次数：坏条目不能无限重试把电和流量耗光。
  static final Map<String, int> _attempts = {};
  static const int maxAttempts = 8;

  /// 每条最后一次失败原因。以前只有「0/37」这种数字，看不出是 403、
  /// 网页当视频、还是地址全空；把原因带进体检结果才能定位。
  static final Map<String, String> _errors = {};

  static int lastFailed = 0;
  static int lastDoneAt = 0;

  static List<ShortVideo> collectVideos() {
    final byKey = <String, ShortVideo>{};
    // 正在播 / 刚播过的条目优先，容量不够时也要先保住它们。
    final recent = _recentKeys();
    if (recent.isNotEmpty) {
      for (final video in ShortVideoRepo.loadAll()) {
        if (!recent.contains(video.key)) continue;
        byKey.putIfAbsent(video.key, () => video);
      }
    }
    // 播放列表是用户明确要连着播的，整份都值得落盘。
    for (final item in ShortVideoPlaylistRepo.load()) {
      final video = item.short;
      if (video != null) byKey.putIfAbsent(video.key, () => video);
    }
    return byKey.values.toList(growable: false);
  }

  /// 最近起播的 key（最多两条）：第一条是正在播，第二条是刚播过的。
  ///
  /// 顺序由 [ShortVideoMediaCache.localPath] 在播放解析入口显式维护，
  /// 不再从 [ShortVideoPlayStats] 的 Set 尾部推断（重复 add 不会重排）。
  static List<String> _recentKeys() =>
      ShortVideoMediaCache.recentPlaybackKeys(2);

  /// 先更新保护名单再单独下载：下载成功后顺手清理不受保护的旧文件。
  static void refreshProtection() {
    final videos = collectVideos();
    ShortVideoMediaCache.protect(
      videos.map((video) => video.key),
      keep: _recentKeys(),
    );
    // 旧版本可能已经把整个收藏夹落了盘；这里立刻压一次，不必等下一次下载。
    unawaited(ShortVideoMediaCache.enforceLimit());
  }

  static void schedule() {
    if (_running) {
      _pending = true;
      return;
    }
    _running = true;
    unawaited(_run().whenComplete(() {
      _running = false;
      if (_pending) {
        _pending = false;
        schedule();
      }
    }));
  }

  static Future<void> _run() async {
    final all = collectVideos();
    final keep = _recentKeys();
    ShortVideoMediaCache.protect(
      all.map((video) => video.key),
      keep: keep,
    );
    // 先按机型硬上限清一轮（6S 是 350MB），别让旧缓存挤占新条目的空间。
    await ShortVideoMediaCache.enforceLimit();
    // 目录已经到上限时不再往里塞：否则下载 → prune 删旧 → 下次再下，白耗流量。
    var used = await ShortVideoMediaCache.size();
    final limit = ShortVideoMediaCache.limitBytes;
    var failed = 0;
    for (final video in all) {
      if (used >= limit && !keep.contains(video.key)) break;
      // 单条失败绝不能中断整批：以前一个 403 会让后面的收藏全部不下。
      try {
        if (await ShortVideoMediaCache.localPath(video, track: false) != null) {
          _attempts.remove(video.key);
          continue;
        }
        if ((_attempts[video.key] ?? 0) >= maxAttempts) continue;
        final result = await _fetchOne(video);
        if (!result.ok) {
          failed++;
          continue;
        }
        final path = result.path;
        if (path != null) {
          try {
            used += await File(path).length();
          } catch (_) {}
        }
        if (used >= limit) break;
      } catch (_) {
        _bump(video.key);
        failed++;
      }
    }
    lastFailed = failed;
    lastDoneAt = DateTime.now().millisecondsSinceEpoch;
    if (failed > 0) _scheduleRetry();
  }

  static Future<ShortVideoDownload> _fetchOne(ShortVideo video) async {
    final platform =
        ShortVideoPlatform.fromId(video.platform) ?? ShortVideoPlatform.douyin;
    final cookie = await ShortVideoWeb.cookieHeader(
      platform.cookieDomainNeedle,
    );
    final stable = stableUrls(video);
    final urls = <String>[
      // TikTok 的长期地址优先；签名直链兜底。
      if (platform == ShortVideoPlatform.tiktok) ...stable,
      if (video.playUrl.isNotEmpty) video.playUrl,
      if (platform != ShortVideoPlatform.tiktok) ...stable,
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
      _attempts.remove(video.key);
      _errors.remove(video.key);
      return result;
    }
    _bump(video.key);
    final reason = (result.error ?? 'unknown').trim();
    _errors[video.key] = reason.length > 160
        ? reason.substring(0, 160)
        : reason;
    return result;
  }

  static void _bump(String key) {
    _attempts.update(key, (value) => value + 1, ifAbsent: () => 1);
  }

  static void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 90), schedule);
  }

  static Map<String, Object?> snapshot() => <String, Object?>{
    'running': _running,
    'pending': _pending,
    'failed': lastFailed,
    'doneAt': lastDoneAt,
    'retryEntries': _attempts.length,
    'attempts': Map<String, int>.of(_attempts),
    'errors': Map<String, String>.of(_errors),
  };
}
