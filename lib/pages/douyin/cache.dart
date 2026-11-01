import 'dart:io';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/utils/path_utils.dart';

/// 短视频的本地媒体缓存。
///
/// 抖音 / TikTok 网页里抄到的直链是签名地址，一是会过期，二是 TikTok 的 CDN
/// 对「非浏览器」的取流（media_kit 走的 libmpv）经常整条拒掉——表现就是每条都
/// 要「换地址重试」还播不出来。这里用 Dart 自己的 HttpClient（带网页那套 UA /
/// Referer）把整条视频下到本地再播，和 Kumone 里「TikTok 走缓存」是同一条路。
abstract final class ShortVideoMediaCache {
  static Directory? _dir;

  /// 正在下载的条目，避免同一条被并发拉两遍。
  static final Set<String> _inFlight = {};

  static Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null && await cached.exists()) return cached;
    final dir = Directory(
      '$tmpDirPath${Platform.pathSeparator}short_video',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return _dir = dir;
  }

  static Future<File> _fileFor(ShortVideo video) async {
    final dir = await _ensureDir();
    final safeId = video.id.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '_');
    return File('${dir.path}${Platform.pathSeparator}${video.platform}_$safeId.mp4');
  }

  /// 已经有完整文件就返回路径，否则 null。
  static Future<String?> localPath(ShortVideo video) async {
    try {
      final file = await _fileFor(video);
      if (!await file.exists()) return null;
      if (await file.length() <= 0) {
        await file.delete();
        return null;
      }
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 下载到本地；成功返回文件路径，全部地址都失败返回 null。
  ///
  /// [urls] 按顺序试，前一个失败换下一个。[onProgress] 传 0~1，用来在播放页
  /// 显示「缓存中 42%」。
  static Future<String?> download(
    ShortVideo video, {
    required List<String> urls,
    required String userAgent,
    required String referer,
    void Function(double progress)? onProgress,
  }) async {
    final key = '${video.platform}:${video.id}';
    if (_inFlight.contains(key)) return localPath(video);
    _inFlight.add(key);
    try {
      final existing = await localPath(video);
      if (existing != null) return existing;
      final target = await _fileFor(video);
      for (final url in urls) {
        if (url.isEmpty) continue;
        final ok = await _fetch(
          url,
          target,
          userAgent: userAgent,
          referer: referer,
          onProgress: onProgress,
        );
        if (ok) return target.path;
      }
      return null;
    } finally {
      _inFlight.remove(key);
    }
  }

  static Future<bool> _fetch(
    String url,
    File target, {
    required String userAgent,
    required String referer,
    void Function(double progress)? onProgress,
  }) async {
    final part = File('${target.path}.part');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(HttpHeaders.refererHeader, referer);
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        return false;
      }
      final mime = response.headers.contentType?.mimeType ?? '';
      if (mime.contains('html')) {
        await response.drain<void>();
        return false;
      }
      final total = response.contentLength;
      var received = 0;
      if (await part.exists()) await part.delete();
      sink = part.openWrite();
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received <= 0) {
        if (await part.exists()) await part.delete();
        return false;
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      onProgress?.call(1);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  /// 删掉这一条的缓存（收藏里删条目时一并调）。
  static Future<void> remove(ShortVideo video) async {
    try {
      final file = await _fileFor(video);
      if (await file.exists()) await file.delete();
      final part = File('${file.path}.part');
      if (await part.exists()) await part.delete();
    } catch (_) {}
  }

  /// 清空整个短视频缓存目录。
  static Future<void> clear() async {
    try {
      final dir = await _ensureDir();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 缓存目录占用（字节），界面上给个数字。
  static Future<int> size() async {
    try {
      final dir = await _ensureDir();
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}