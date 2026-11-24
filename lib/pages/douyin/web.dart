import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:flutter/services.dart';

/// 抓取网页的原生桥。
///
/// 抖音 / TikTok 的收藏页必须跑真实页面（接口要签名），而 flutter_inappwebview
/// 在这套 iOS 构建里创建出来只有一片白——它是 Flutter 的 platform view。所以这里
/// 直接调原生 WKWebView（`ios/Runner/AppDelegate.swift` 里的
/// `ShortVideoWebViewPlugin`），和 Kumone 走同一条已验证的代码路径。
abstract final class ShortVideoWeb {
  static const MethodChannel _channel = MethodChannel(
    'piliplus/shortvideo_web',
  );

  static bool _installed = false;

  /// 原生抓到一段 JSON。
  static void Function(String body)? onPayload;

  /// 原生那边的状态文字（页面加载、抓取进度、错误）。
  static void Function(String text)? onStatus;

  /// 用户关掉网页。
  static void Function()? onClosed;

  static void _ensureHandler() {
    if (_installed) return;
    _installed = true;
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      switch (call.method) {
        case 'payload':
          if (args is Map && args['body'] is String) {
            onPayload?.call(args['body'] as String);
          }
        case 'status':
          if (args is String) onStatus?.call(args);
        case 'closed':
          onClosed?.call();
        case 'downloadProgress':
          if (args is Map) {
            final id = args['id'];
            final value = args['progress'];
            if (id is int && value is num) {
              _downloadProgress[id]?.call(value.toDouble());
            }
          }
      }
      return null;
    });
  }

  static Future<void> open(
    ShortVideoPlatform platform, {
    int knownCount = 0,
    bool autoStart = false,
  }) async {
    _ensureHandler();
    await _channel.invokeMethod('open', {
      'url': platform.homeUrl,
      'favoritesUrl': platform.favoritesUrl,
      'loginUrl': platform.loginUrl,
      // 1.5s 内没看到登录浮层时原生直接 load 这个地址：抖音只有首页前端
      // 会拉起登录浮层，TikTok 用自己的 /login 页。
      'loginFallbackUrl': platform.id == 'douyin'
          ? platform.siteUrl
          : 'https://www.tiktok.com/login',
      'cookieDomain': platform.cookieDomainNeedle,
      'userAgent': platform.userAgent,
      'title': '${platform.album} · 登录与抓取',
      'hookScript': hookJs(platform),
      'driverScript': driverJs(platform, knownCount: knownCount),
    });
    // 直接同步入口：打开后立刻让原生切到收藏页并开始抓取。
    if (autoStart) await _channel.invokeMethod('start');
  }

  /// 设备物理内存（字节）。取不到返回 0。
  ///
  /// 用来决定要不要走「低内存」那套保守策略（见 ShortVideoPerf）。
  static Future<int> deviceMemory() async {
    _ensureHandler();
    try {
      final bytes = await _channel.invokeMethod<int>('deviceMemory');
      return bytes ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 网页那套 cookie。
  ///
  /// 抖音 / TikTok 的 CDN 会按网页会话校验（TikTok 尤其明显）；Kumone 那边用
  /// URLSession 下载，天然和 WKWebView 共用 cookie，所以下得动。Dart 的
  /// HttpClient 是独立 cookie 罐，不带就是 403 / 0 字节——这里把网页的 cookie
  /// 取过来手动带上。
  static final Map<String, String> _cookieCache = {};
  static final Map<String, DateTime> _cookieAt = {};

  static Future<String> cookieHeader(String domain) async {
    if (domain.isEmpty) return '';
    final at = _cookieAt[domain];
    if (at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _cookieCache[domain] ?? '';
    }
    _ensureHandler();
    try {
      final list = await _channel.invokeMethod<List<dynamic>>('cookies', {
        'domain': domain,
      });
      if (list == null) return '';
      final byName = <String, String>{};
      for (final entry in list) {
        if (entry is! Map) continue;
        final name = '${entry['name'] ?? ''}';
        final value = '${entry['value'] ?? ''}';
        if (name.isEmpty) continue;
        byName[name] = value;
      }
      final header = byName.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
      _cookieCache[domain] = header;
      _cookieAt[domain] = DateTime.now();
      return header;
    } catch (_) {
      return '';
    }
  }

  static void clearCookieCache() {
    _cookieCache.clear();
    _cookieAt.clear();
    _playUrlCache.clear();
    _playUrlAt.clear();
  }

  /// 重新解析出来的直链，20 分钟内复用。
  static final Map<String, String> _playUrlCache = {};
  static final Map<String, DateTime> _playUrlAt = {};

  /// 最近一次直链解析失败的原因：
  /// `network`（网络）/ `login`（需要登录）/ `notfound`（解析不到）。
  static String lastPlayUrlError = '';

  /// 让原生这边开一个离屏网页，把一条视频的新直链重新解析出来。
  ///
  /// 收藏里存的是签名直链，过几个小时就 403；TikTok 官方的「长期地址」
  /// （tiktokv.com）实测全返回 HTTP 400，只能回页面里重新拿。
  static Future<String?> resolvePlayUrl({
    required String platformId,
    required String videoId,
    required String userAgent,
  }) async {
    lastPlayUrlError = '';
    if (videoId.isEmpty) {
      lastPlayUrlError = 'notfound';
      return null;
    }
    final cacheKey = '$platformId:$videoId';
    final at = _playUrlAt[cacheKey];
    if (at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 20)) {
      final cached = _playUrlCache[cacheKey];
      if (cached != null && cached.isNotEmpty) return cached;
    }
    _ensureHandler();
    try {
      final raw = await _channel.invokeMethod<dynamic>('resolvePlayUrl', {
        'platform': platformId,
        'videoId': videoId,
        'userAgent': userAgent,
      });
      String? url;
      var reason = '';
      if (raw is Map) {
        final value = raw['url'];
        if (value is String && value.isNotEmpty) url = value;
        final detail = raw['reason'];
        if (detail is String) reason = detail;
      } else if (raw is String && raw.isNotEmpty) {
        // 兼容旧原生只返回 URL 的情况。
        url = raw;
      }
      if (url == null || url.isEmpty) {
        lastPlayUrlError = reason.isEmpty ? 'notfound' : reason;
        return null;
      }
      _playUrlCache[cacheKey] = url;
      _playUrlAt[cacheKey] = DateTime.now();
      return url;
    } catch (_) {
      lastPlayUrlError = 'network';
      return null;
    }
  }

  /// 展开 `v.douyin.com` / `vm.tiktok.com` 这类短链，返回最终地址。
  ///
  /// 短链的 `Location` 里就带着 videoId，只看重定向头，不下载整个页面。
  /// 最多跟 5 跳，失败返回 null（由调用方提示用户粘贴完整链接）。
  static Future<String?> expandShortLink(
    String input, {
    required String userAgent,
  }) async {
    final parsed = Uri.tryParse(_firstUrl(input));
    if (parsed == null || !parsed.hasAuthority) return null;
    if (!parsed.isScheme('http') && !parsed.isScheme('https')) return null;
    var current = parsed;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      for (var hop = 0; hop < 5; hop++) {
        final request = await client
            .getUrl(current)
            .timeout(const Duration(seconds: 8));
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        // 必须把响应体排空，否则连接会一直占着，下一跳复用不了。
        await response.drain<void>().timeout(const Duration(seconds: 5));
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || location.isEmpty) {
          return response.isRedirect ? null : current.toString();
        }
        current = current.resolve(location);
      }
      return current.toString();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 用户常把 App 的整段分享文案一起粘过来（前面有说明、后面还有
  /// `vSy:/ :8pm 05/06 i@C.hO` 这类尾巴）。这里只取第一个 http(s) 地址，
  /// 并把粘在地址末尾的标点 / 中文去掉。
  static final RegExp _urlPattern = RegExp(
    r"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+",
    caseSensitive: false,
  );

  static final RegExp _trailingJunk = RegExp(
    r'''[.,;:!?'"）)】\]》」』”’>]+$''',
  );

  static String _firstUrl(String input) {
    final match = _urlPattern.firstMatch(input);
    if (match == null) return input.trim();
    var value = match.group(0)!;
    while (value.isNotEmpty) {
      final next = value.replaceFirst(_trailingJunk, '');
      if (next == value) break;
      value = next;
    }
    return value;
  }

  static int _downloadSeq = 0;
  static final Map<int, void Function(double)> _downloadProgress = {};

  /// 最近一次原生下载的失败原因（给体检结果用）。
  static String lastDownloadError = '';

  /// 原生 URLSession 下载，成功返回本地路径。
  ///
  /// 关键差别在于 cookie：这里把 WKWebView 的整罐 cookie 显式塞进请求头，
  /// 而 Dart 的 HttpClient 是另一套罐子，TikTok 的 CDN 认的就是前者。
  static Future<String?> nativeDownload({
    required List<String> urls,
    required String destPath,
    required String userAgent,
    required String referer,
    required String cookieDomain,
    void Function(double progress)? onProgress,
  }) async {
    final targets = urls.where((url) => url.isNotEmpty).toList(growable: false);
    if (targets.isEmpty || destPath.isEmpty) return null;
    _ensureHandler();
    final id = ++_downloadSeq;
    if (onProgress != null) _downloadProgress[id] = onProgress;
    lastDownloadError = '';
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'download',
        {
          'id': id,
          'urls': targets,
          'destPath': destPath,
          'userAgent': userAgent,
          'referer': referer,
          'cookieDomain': cookieDomain,
        },
      );
      final path = result?['path'];
      if (path is String && path.isNotEmpty) return path;
      final error = result?['error'];
      lastDownloadError = error is String && error.isNotEmpty
          ? error
          : '原生下载失败';
      return null;
    } catch (e) {
      lastDownloadError = '$e';
      return null;
    } finally {
      _downloadProgress.remove(id);
    }
  }

  static Future<void> start() => _channel.invokeMethod('start');

  static Future<void> stop() => _channel.invokeMethod('stop');

  static Future<void> close() => _channel.invokeMethod('close');
}

/// 包住 `fetch` / `XMLHttpRequest`，凡是返回体里带平台特征字段的都回传原生。
String hookJs(ShortVideoPlatform platform) {
  final markers = platform.markers.map((e) => "'$e'").join(',');
  return '''
(function () {
  if (window.__kumoneShortVideoHook) { return; }
  window.__kumoneShortVideoHook = true;

  var MARKERS = [$markers];

  function interesting(text) {
    if (!text || text.length < 40) { return false; }
    for (var i = 0; i < MARKERS.length; i++) {
      if (text.indexOf(MARKERS[i]) >= 0) { return true; }
    }
    return false;
  }

  function post(url, text) {
    try {
      if (!interesting(text)) { return; }
      // 记下页面上累计见过多少条：驱动脚本靠它判断「是否已经抓够本地基线」。
      try {
        // 只数明确的视频 id 字段，避免把 "id": 之类的杂项算进去导致提前停止滚动。
        var ids = text.match(/"(?:aweme_id|item_id)"\\s*:\\s*"?([0-9]{8,})/g);
        if (ids) {
          window.__kumoneSeenCount = (window.__kumoneSeenCount || 0) + ids.length;
        }
      } catch (e) {}
      window.webkit.messageHandlers.shortvideo.postMessage({
        url: String(url),
        body: text
      });
    } catch (e) {}
  }

  var originalFetch = window.fetch;
  if (originalFetch) {
    window.fetch = function () {
      var args = arguments;
      var url = '';
      try { url = (args[0] && args[0].url) ? args[0].url : args[0]; } catch (e) {}
      var promise = originalFetch.apply(this, args);
      try {
        promise.then(function (response) {
          try {
            response.clone().text().then(function (text) { post(url, text); }).catch(function () {});
          } catch (e) {}
        }).catch(function () {});
      } catch (e) {}
      return promise;
    };
  }

  var open = XMLHttpRequest.prototype.open;
  var send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__kumoneURL = url;
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    var xhr = this;
    try {
      xhr.addEventListener('load', function () {
        try { post(xhr.__kumoneURL, xhr.responseText); } catch (e) {}
      });
    } catch (e) {}
    return send.apply(this, arguments);
  };
})();
''';
}

/// 自动点开「收藏」tab，并持续滚到底，让列表继续分页。
///
/// `knownCount` 是本地已经有的收藏条数（0 表示没有本地基线）。
/// 一旦页面上累计见过的条目达到这个数、且连续若干轮没有新增，就停止滚动：
/// 收藏几百条时，无限滚动会把整个收藏夹从头拉一遍，用户感受到的就是
/// 「每次同步都把整个收藏夹重新解析/重新收藏一遍」。只要新增的部分抓到了，
/// 剩下的旧条目本地本来就有，没必要再滚。
String driverJs(ShortVideoPlatform platform, {int knownCount = 0}) {
  final titles = platform.tabTitles.map((e) => "'$e'").join(',');
  return '''
(function () {
  if (window.__kumoneDriver) { return; }
  var TITLES = [$titles];
  var KNOWN = $knownCount;
  var idleRounds = 0;
  var lastHeight = 0;
  window.__kumoneDriver = setInterval(function () {
    try {
      if (!window.__kumoneClickedTab) {
        var nodes = document.querySelectorAll('div,span,a,li,button');
        for (var i = 0; i < nodes.length; i++) {
          var text = (nodes[i].textContent || '').trim();
          for (var t = 0; t < TITLES.length; t++) {
            if (text === TITLES[t]) {
              nodes[i].click();
              window.__kumoneClickedTab = true;
              return;
            }
          }
        }
        return;
      }
      var height = document.body.scrollHeight;
      if (height === lastHeight) {
        idleRounds = idleRounds + 1;
      } else {
        idleRounds = 0;
        lastHeight = height;
      }
      // 滚不动了：已经到底，或者能拉的都拉完了。
      if (idleRounds >= 4) {
        clearInterval(window.__kumoneDriver);
        window.__kumoneDriver = null;
        return;
      }
      // 已经攒够本地基线那么多条、又连续两轮没有新的：就停，不再无谓地翻旧数据。
      if (KNOWN > 0 && window.__kumoneSeenCount >= KNOWN && idleRounds >= 2) {
        clearInterval(window.__kumoneDriver);
        window.__kumoneDriver = null;
        return;
      }
      window.scrollTo(0, height);
    } catch (e) {}
  }, 1200);
})();
''';
}
