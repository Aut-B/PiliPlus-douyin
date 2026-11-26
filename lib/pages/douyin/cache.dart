import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/perf.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
import 'package:PiliPlus/utils/path_utils.dart';

/// 一次缓存下载的结果。[path] 有值表示成功，否则 [error] 说明卡在哪一步。
class ShortVideoDownload {
  const ShortVideoDownload({this.path, this.error});

  final String? path;
  final String? error;

  bool get ok => path != null;
}

/// 短视频的本地媒体缓存。
///
/// 抖音 / TikTok 网页里抄到的直链是签名地址，一是会过期，二是 CDN 会按网页
/// 会话校验（TikTok 尤其严）。Kumone 那边用 URLSession 下载，天然和 WKWebView
/// 共用 cookie，所以下得动；Dart 的 HttpClient 是独立 cookie 罐，一个都不带，
/// 结果就是「缓存中 0% → 直链和缓存都失败了」。
///
/// 所以这里必须显式带上网页的 cookie（见 ShortVideoWeb.cookieHeader）。
abstract final class ShortVideoMediaCache {
  static Directory? _dir;

  static Future<void> _migration = Future<void>.value();

  /// 正在下载的条目，避免同一条被并发拉两遍。
  static final Set<String> _inFlight = {};

  /// 播放列表 / 最近起播的 key。先淘汰不在这个集合里的文件，再淘汰这里的。
  static Set<String> _protectedKeys = const <String>{};

  /// 保底不能让容量上限删掉的 key（正在播 + 最近一条）。
  static Set<String> _keepKeys = const <String>{};

  /// 手动缓存批次临时纳入的 key。
  ///
  /// 用户选中的条目多数不在播放列表里；批次期间把它们也算作受保护，
  /// 下载触发的 prune 才不会把刚存下的文件当普通缓存删掉。
  static Set<String> _manualKeys = const <String>{};

  /// 最近被播放路径访问的 key（新 → 旧）。
  ///
  /// `ShortVideoPlayStats` 里的两个 Set 重复 add 不会重排，从尾部推断不出
  /// 真正的「正在播」。播放解析一定会先经过 [localPath]，这里用
  /// move-to-front 记录真实访问顺序；批量扫描传 `track: false`，不会污染。
  static final List<String> _playbackKeys = <String>[];
  static const int _playbackHistory = 6;

  /// 最近起播的 key，新的在前（默认「正在播 + 上一条」）。
  static List<String> recentPlaybackKeys([int limit = 2]) {
    if (limit <= 0 || _playbackKeys.isEmpty) return const <String>[];
    final count = limit > _playbackKeys.length ? _playbackKeys.length : limit;
    return _playbackKeys.take(count).toList(growable: false);
  }

  static void _notePlayback(String key) {
    if (key.isEmpty) return;
    _playbackKeys.remove(key);
    _playbackKeys.insert(0, key);
    if (_playbackKeys.length > _playbackHistory) {
      _playbackKeys.removeRange(_playbackHistory, _playbackKeys.length);
    }
  }

  /// 当前硬保底的 key：正在播的那条和最近一条。
  ///
  /// 每次 prune 都从 [_playbackKeys] 现取，而不是用 [protect] 时的快照；
  /// 否则扫盘期间用户换了正在播的视频，旧快照会漏掉新条目，误把它删掉。
  static Set<String> _activeKeepKeys() {
    final recent = recentPlaybackKeys(2).where((key) => key.isNotEmpty);
    if (recent.isNotEmpty) return recent.toSet();
    // 还没记录到播放路径时沿用 protect 传入的保底（通常是空集）。
    return _keepKeys;
  }

  /// 目录只解析一次。
  ///
  /// 原实现每次调用都 `await cached.exists()`，并且无条件把迁移挂到
  /// `_migration` 链上再 await 它。缓存里有几百 MB 时，这条链上的
  /// `_migrateLegacyCache` 会遍历整个临时目录、逐个 `copy`，而它排在
  /// **开播前的关键路径**上（localPath → _fileFor → _ensureDir）。
  /// 这就是「右下角都显示缓存 281MB 了，起播还要很久」的直接原因：
  /// 不是读不到缓存，是读之前先等了一次全量目录迁移。
  ///
  /// 现在改成：初始化一次，之后立即返回；迁移只在第一次真正执行。
  static Future<Directory> _ensureDir() {
    final ready = _dirReady;
    if (ready != null) return ready;
    return _dirReady = _initDir();
  }

  static Future<Directory>? _dirReady;

  static Future<Directory> _initDir() async {
    final dir = Directory(
      '$appSupportDirPath${Platform.pathSeparator}short_video',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    // 迁移放后台，不挡开播。失败也无所谓，只是旧缓存少一份。
    _migration = _migration.then((_) => _migrateLegacyCache(dir));
    return dir;
  }

  static Future<void> _migrateLegacyCache(Directory target) async {
    final legacy = Directory(
      '$tmpDirPath${Platform.pathSeparator}short_video',
    );
    if (!await legacy.exists()) return;
    await for (final entity in legacy.list()) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.part')) continue;
      final destination = File(
        '${target.path}${Platform.pathSeparator}'
        '${entity.uri.pathSegments.last}',
      );
      if (await destination.exists()) continue;
      try {
        await entity.copy(destination.path);
      } catch (_) {}
    }
  }

  /// 刷新受保护 key。
  ///
  /// [keys] 只是「优先保留」：超过容量上限时它们也会被淘汰；[keep] 是调用时的
  /// 硬保底，prune 时仍会以当时的 [recentPlaybackKeys] 为准。
  static void protect(
    Iterable<String> keys, {
    Iterable<String> keep = const <String>[],
  }) {
    _protectedKeys = keys.toSet();
    _keepKeys = keep.toSet();
  }

  /// 手动缓存一批条目时调用；批次结束务必 [endManualCache]。
  static void beginManualCache(Iterable<String> keys) {
    _manualKeys = keys.toSet();
  }

  static void endManualCache() {
    _manualKeys = const <String>{};
  }

  static Set<String> _protectNow() => _manualKeys.isEmpty
      ? _protectedKeys
      : <String>{..._protectedKeys, ..._manualKeys};

  /// 当前机型的缓存硬上限（字节）。
  static int get limitBytes => ShortVideoPerf.cacheLimitBytes;

  static String _fileKeyOf(String fileName) {
    if (!fileName.endsWith('.mp4')) return '';
    final name = fileName.substring(0, fileName.length - 4);
    final separator = name.indexOf('_');
    if (separator <= 0) return '';
    return '${name.substring(0, separator)}:${name.substring(separator + 1)}';
  }

  static Future<File> _fileFor(ShortVideo video) async {
    final dir = await _ensureDir();
    final safeId = video.id.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '_');
    return File(
      '${dir.path}${Platform.pathSeparator}${video.platform}_$safeId.mp4',
    );
  }

  /// 已经有完整文件就返回路径，否则 null。
  ///
  /// 只有真正的播放解析入口才传 `track: true`（move-to-front）；批量扫描、
  /// 缓存写入后的复核一律用默认的 `false`，否则整个收藏列表都会被当成
  /// 正在播，把真实播放条目挤出保底集合。
  static Future<String?> localPath(
    ShortVideo video, {
    bool track = false,
  }) async {
    if (track) _notePlayback(video.key);
    return _existingPath(video);
  }

  static Future<String?> _existingPath(ShortVideo video) async {
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

  /// 下载到本地。[urls] 按顺序试，前一个失败换下一个。
  static Future<ShortVideoDownload> download(
    ShortVideo video, {
    required List<String> urls,
    required String userAgent,
    required String referer,
    String cookie = '',
    String appUserAgent = '',
    void Function(double progress)? onProgress,
  }) async {
    await _ensureDir();
    // 串行下载：低内存机型上并发下载会把进程顶掉，CDN 也会限速。
    return _serialized(
      () => _download(
        video,
        urls: urls,
        userAgent: userAgent,
        referer: referer,
        cookie: cookie,
        appUserAgent: appUserAgent,
        onProgress: onProgress,
      ),
    );
  }

  static Future<ShortVideoDownload> _download(
    ShortVideo video, {
    required List<String> urls,
    required String userAgent,
    required String referer,
    String cookie = '',
    String appUserAgent = '',
    void Function(double progress)? onProgress,
  }) async {
    await ShortVideoPerf.ensureProbed();
    final key = '${video.platform}:${video.id}';
    if (_inFlight.contains(key)) {
      final existing = await _existingPath(video);
      return ShortVideoDownload(
        path: existing,
        error: existing == null ? '这条正在下载' : null,
      );
    }
    _inFlight.add(key);
    try {
      final existing = await _existingPath(video);
      if (existing != null) return ShortVideoDownload(path: existing);
      final target = await _fileFor(video);
      final errors = <String>[];

      // 一、原生 URLSession。TikTok 的 CDN 认的是网页会话的 cookie，Dart 的
      // HttpClient 带不上，所以这条路径才是「下得动」的那条（Kumone 同源）。
      final cookieDomain = video.platform == 'tiktok'
          ? 'tiktok.com'
          : 'douyin.com';
      final nativePath = await ShortVideoWeb.nativeDownload(
        urls: urls,
        destPath: target.path,
        userAgent: userAgent,
        referer: referer,
        cookieDomain: cookieDomain,
        onProgress: onProgress,
      );
      if (nativePath != null) {
        return await _settle(video);
      }
      if (ShortVideoWeb.lastDownloadError.isNotEmpty) {
        errors.add('native: ${ShortVideoWeb.lastDownloadError}');
      }

      // 二、收藏里存的是签名直链，过一阵必然 403。用 videoId 回视频页重新
      // 解析一条新地址再下一次。
      if (video.videoId.isNotEmpty) {
        final fresh = await ShortVideoWeb.resolvePlayUrl(
          platformId: video.platform,
          videoId: video.videoId,
          userAgent: userAgent,
        );
        if (fresh != null) {
          final retried = await ShortVideoWeb.nativeDownload(
            urls: [fresh.url],
            destPath: target.path,
            userAgent: userAgent,
            referer: referer,
            cookieDomain: cookieDomain,
            onProgress: onProgress,
          );
          if (retried != null) {
            return await _settle(video);
          }
          errors.add('fresh: ${ShortVideoWeb.lastDownloadError}');
        } else {
          errors.add('fresh: 没解析出新地址');
        }
      }

      // 三、Dart 兜底（抖音一直走这条也能成）。
      for (final url in urls) {
        if (url.isEmpty) continue;
        final error = await _fetch(
          url,
          target,
          userAgent: _uaFor(url, userAgent, appUserAgent),
          referer: referer,
          cookie: cookie,
          onProgress: onProgress,
        );
        if (error == null) {
          return await _settle(video);
        }
        errors.add('${_hostOf(url)}: $error');
      }
      return ShortVideoDownload(
        error: errors.isEmpty ? '没有可用的地址' : errors.join(' / '),
      );
    } finally {
      _inFlight.remove(key);
    }
  }

  /// 下载成功后先等一次容量淘汰落定，再以磁盘为准返回结果。
  ///
  /// 以前 `unawaited(_prune())` 就直接返回 path，prune 可能紧接着把刚写下的
  /// 文件淘汰掉，调用方却把这条记成「已缓存」。这里串行等 prune 完成并复核
  /// [localPath]，文件不在了就明确返回失败。
  static Future<ShortVideoDownload> _settle(ShortVideo video) async {
    await _prune();
    final path = await _existingPath(video);
    if (path == null) {
      return const ShortVideoDownload(error: '本地缓存已满，这条未能保留');
    }
    return ShortVideoDownload(path: path);
  }

  /// 长期地址（tiktokv.com）只认 App 的 UA，签名直链则要用网页 UA。
  static String _uaFor(String url, String webUa, String appUa) {
    if (appUa.isEmpty) return webUa;
    final host = _hostOf(url).toLowerCase();
    if (host.contains('tiktokv.com') || host.contains('snssdk.com')) {
      return appUa;
    }
    return webUa;
  }

  static String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  /// 成功返回 null，失败返回原因。
  static Future<String?> _fetch(
    String url,
    File target, {
    required String userAgent,
    required String referer,
    required String cookie,
    void Function(double progress)? onProgress,
  }) async {
    final part = File('${target.path}.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..maxConnectionsPerHost = 4;
    IOSink? sink;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, userAgent);
      request.headers.set(HttpHeaders.refererHeader, referer);
      // TikTok 的 CDN（v16-webapp-prime 等）在没有 Range / Accept 时经常直接
      // 回 403 或者一整页 HTML；抖音这边带上也无害。
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      request.headers.set(
        HttpHeaders.acceptLanguageHeader,
        'en-US,en;q=0.9,zh-CN;q=0.8',
      );
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
      if (cookie.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookie);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        return 'HTTP ${response.statusCode}';
      }
      final mime = response.headers.contentType?.mimeType ?? '';
      if (mime.contains('html')) {
        await response.drain<void>();
        return '返回的是网页不是视频';
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
        return '下载到 0 字节';
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      onProgress?.call(1);
      return null;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
      return '$e';
    } finally {
      client.close(force: true);
    }
  }

  /// 全局串行闸门：一次只跑一条下载。
  static Future<void> _gate = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _gate;
    final done = Completer<void>();
    _gate = done.future;
    try {
      await previous;
      return await action();
    } finally {
      done.complete();
    }
  }

  /// 立即按当前容量上限压一次目录（后台下载前后都能调）。
  static Future<void> enforceLimit() => _prune();

  static Future<void>? _pruneTask;
  static bool _pruneQueued = false;

  /// 串行执行 prune：下载成功后会连发多次，并发删同一批文件会重复计数。
  static Future<void> _prune() {
    final running = _pruneTask;
    if (running != null) {
      _pruneQueued = true;
      return running;
    }
    final task = _pruneLoop();
    _pruneTask = task;
    return task;
  }

  static Future<void> _pruneLoop() async {
    try {
      do {
        _pruneQueued = false;
        try {
          await _pruneOnce();
        } catch (_) {}
      } while (_pruneQueued);
    } finally {
      _pruneTask = null;
    }
  }

  /// 超过上限就把最旧的删掉（低内存机型上限更小）。
  ///
  /// 受保护文件也计入 total，超限时同样按最旧淘汰；只是排在普通文件之后，
  /// 尽量晚删。硬保底是删除时现取的「正在播 + 最近一条」。
  static Future<void> _pruneOnce() async {
    // 上限取决于机型内存，先探测一次；否则 6S 在首次下载前会误用 3GB。
    await ShortVideoPerf.ensureProbed();
    final limit = ShortVideoPerf.cacheLimitBytes;
    final dir = await _ensureDir();
    if (!await dir.exists()) return;
    final entries = <({File file, DateTime at, int size, String key})>[];
    var total = 0;
    // 崩溃留下的 .part 既占盘又永远不会被淘汰；一小时以上的视为陈旧，
    // 计入总量并参与淘汰。进行中的下载会持续刷新 mtime，不会被误删。
    final stalePartBefore = DateTime.now().subtract(const Duration(hours: 1));
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final isPart = entity.path.endsWith('.part');
      try {
        final at = await entity.lastModified();
        if (isPart && at.isAfter(stalePartBefore)) continue;
        final size = await entity.length();
        total += size;
        entries.add((
          file: entity,
          at: at,
          size: size,
          key: isPart ? '' : _fileKeyOf(entity.uri.pathSegments.last),
        ));
      } catch (_) {}
    }
    if (total <= limit || entries.isEmpty) return;

    final entryKeys = entries
        .map((entry) => entry.key)
        .where((key) => key.isNotEmpty)
        .toSet();
    final remaining = [...entries];
    while (total > limit && remaining.isNotEmpty) {
      // 每一步都重读当前播放顺序，prune 期间刚起播的条目不按旧快照删。
      final keepNow = _activeKeepKeys();
      final protectNow = _protectNow();
      final diskKeep = keepNow.any(
        (key) => key.isNotEmpty && entryKeys.contains(key),
      );
      // keep 里的条目可能还没落盘（比如正在播的这条只有网络直链）；
      // 这种情况下仍然保底留一条最新的视频，别把缓存目录清空。
      final fallbackKey = diskKeep ? '' : _fallbackKeyOf(remaining, protectNow);

      bool protectedKeep(
        ({File file, DateTime at, int size, String key}) entry,
      ) => entry.key.isNotEmpty && keepNow.contains(entry.key);
      final ordinary =
          remaining
              .where(
                (entry) =>
                    !protectNow.contains(entry.key) &&
                    !protectedKeep(entry) &&
                    !(fallbackKey.isNotEmpty && entry.key == fallbackKey),
              )
              .toList()
            ..sort((a, b) => a.at.compareTo(b.at));
      final protected =
          remaining
              .where(
                (entry) =>
                    protectNow.contains(entry.key) &&
                    !protectedKeep(entry) &&
                    !(fallbackKey.isNotEmpty && entry.key == fallbackKey),
              )
              .toList()
            ..sort((a, b) => a.at.compareTo(b.at));
      final candidate = ordinary.isNotEmpty
          ? ordinary.first
          : (protected.isNotEmpty ? protected.first : null);
      // 剩下的全是 keep / 兜底条目：硬保底，不能再删。
      if (candidate == null) break;

      // 删除前再同步确认一次，绝不删当时正在播的那条。
      final guardKeep = _activeKeepKeys();
      if (candidate.key.isNotEmpty && guardKeep.contains(candidate.key)) {
        continue;
      }
      remaining.remove(candidate);
      try {
        await candidate.file.delete();
        total -= candidate.size;
        entryKeys.remove(candidate.key);
      } catch (_) {}
    }
  }

  /// 没有硬保底条目落盘时，至少再留一条最新的视频（优先受保护条目）。
  ///
  /// key 为空的非视频残留不享受保底，否则它们会一直占着上限。
  static String _fallbackKeyOf(
    List<({File file, DateTime at, int size, String key})> entries,
    Set<String> protectKeys,
  ) {
    final protectedEntries = entries
        .where((entry) => protectKeys.contains(entry.key))
        .toList(growable: false);
    final pool = protectedEntries.isEmpty ? entries : protectedEntries;
    final videoEntries = pool
        .where((entry) => entry.key.isNotEmpty)
        .toList(growable: false);
    final candidates = videoEntries.isEmpty ? pool : videoEntries;
    if (candidates.isEmpty) return '';
    var newest = candidates.first;
    for (final entry in candidates) {
      if (entry.at.isAfter(newest.at)) newest = entry;
    }
    return newest.key;
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
