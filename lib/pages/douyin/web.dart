import 'dart:async';
import 'dart:collection';

import 'package:PiliPlus/pages/douyin/models.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 全屏的抓取页：网页在这里登录、滚动，我们只旁观它拿到的 JSON。
///
/// 单独一页、而且 `InAppWebView` 直接做 `Scaffold.body`（拿到紧约束），是刻意的：
/// iOS 上它是 platform view，放在 `Stack` / `IndexedStack` 这类给**松约束**的
/// 容器里会被量成 0 高度，整页就只剩白屏。
class ShortVideoWebPage extends StatefulWidget {
  const ShortVideoWebPage({super.key, required this.platform});

  final ShortVideoPlatform platform;

  @override
  State<ShortVideoWebPage> createState() => _ShortVideoWebPageState();
}

class _ShortVideoWebPageState extends State<ShortVideoWebPage> {
  InAppWebViewController? _web;
  final List<ShortVideo> _videos = [];

  bool _collecting = false;
  String _status = '';
  double _progress = 0;
  Timer? _timer;
  int _idle = 0;
  int _lastCount = 0;
  DateTime? _startedAt;

  ShortVideoPlatform get platform => widget.platform;

  @override
  void initState() {
    super.initState();
    _videos.addAll(ShortVideoRepo.load(platform));
    _status = _videos.isEmpty
        ? '在网页里登录 ${platform.album}，然后点「开始抓取」'
        : '已加载上次抓取的 ${_videos.length} 条';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  InAppWebViewSettings _settings(String userAgent, {bool mobile = false}) =>
      InAppWebViewSettings(
        userAgent: userAgent,
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        mediaPlaybackRequiresUserGesture: false,
        thirdPartyCookiesEnabled: true,
        allowsInlineMediaPlayback: true,
        preferredContentMode: mobile
            ? UserPreferredContentMode.MOBILE
            : UserPreferredContentMode.DESKTOP,
        useShouldOverrideUrlLoading: true,
      );

  // MARK: - 导航

  Future<void> _load(String url, String userAgent, {bool mobile = false}) async {
    final uri = WebUri(url);
    final controller = _web;
    if (controller == null) return;
    await controller.setSettings(
      settings: _settings(userAgent, mobile: mobile),
    );
    await controller.loadUrl(urlRequest: URLRequest(url: uri));
  }

  /// 收藏页（桌面 UA）。
  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        _status = '正在打开 ${platform.album} 收藏页…';
        _progress = 0;
      });
    }
    await _load(platform.homeUrl, platform.userAgent);
  }

  /// 站点首页：登录面板一般在这里弹出来。
  Future<void> _openHome() async {
    if (mounted) setState(() => _status = '正在打开 ${platform.album} 首页…');
    await _load(platform.siteUrl, platform.userAgent);
  }

  /// 直接打开站点登录页：桌面版右上角「登录」按钮在某些 WebView 里点不动，
  /// 跳登录页最省事；登录完 cookie 落在同一个域上，点刷新回收藏页即可。
  Future<void> _openLogin() async {
    if (mounted) {
      setState(() => _status = '登录页：登录完成后点右上角刷新回收藏页');
    }
    await _load(platform.loginUrl, platform.userAgent);
  }

  // MARK: - 抓取

  void _start() {
    if (_collecting) return;
    setState(() {
      _collecting = true;
      _idle = 0;
      _lastCount = _videos.length;
      _startedAt = DateTime.now();
      _status = '正在抓取…如果一直没动静，请先在网页里登录 ${platform.album}';
    });
    _web?.evaluateJavascript(source: _driverJs(platform));
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _tick(),
    );
  }

  void _stop([String? message]) {
    _timer?.cancel();
    _timer = null;
    _web?.evaluateJavascript(
      source:
          'try{clearInterval(window.__kumoneDriver);'
          'window.__kumoneDriver=null;}catch(e){}',
    );
    _save();
    if (!mounted) return;
    setState(() {
      _collecting = false;
      _status = message ?? '已抓取 ${_videos.length} 条';
    });
  }

  void _tick() {
    if (!_collecting) return;
    _web?.evaluateJavascript(
      source: 'window.scrollTo(0, document.body.scrollHeight);',
    );
    final startedAt = _startedAt;
    if (startedAt != null &&
        DateTime.now().difference(startedAt) > const Duration(minutes: 5)) {
      _stop('抓取超时，已保留 ${_videos.length} 条');
      return;
    }
    if (_videos.length == _lastCount) {
      _idle++;
    } else {
      _idle = 0;
      _lastCount = _videos.length;
    }
    if (_idle >= 10) {
      _stop('抓取完成，共 ${_videos.length} 条');
    }
  }

  void _save() {
    ShortVideoRepo.save(platform, _videos);
  }

  void _ingest(String body) {
    final parsed = ShortVideoParser.fromResponseBody(body, platform);
    if (parsed.isEmpty) return;

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
    if (mounted) {
      setState(() => _status = '已抓取 ${_videos.length} 条…');
    }
    _save();
  }

  // MARK: - UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${platform.album} · 登录与抓取'),
        actions: [
          IconButton(
            tooltip: '首页',
            onPressed: _openHome,
            icon: const Icon(Icons.home_outlined),
          ),
          IconButton(
            tooltip: '登录页',
            onPressed: _openLogin,
            icon: const Icon(Icons.login),
          ),
          IconButton(
            tooltip: '重新加载收藏页',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('完成'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _progress > 0 && _progress < 1
              ? LinearProgressIndicator(value: _progress, minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      // 直接作为 body，拿到紧约束；platform view 才不会缩成 0。
      body: SafeArea(
        top: false,
        child: SizedBox.expand(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(platform.homeUrl)),
            initialSettings: _settings(platform.userAgent),
            initialUserScripts: UnmodifiableListView<UserScript>([
              UserScript(
                source: _hookJs(platform),
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                forMainFrameOnly: false,
              ),
            ]),
            onWebViewCreated: (controller) {
              _web = controller;
              controller.addJavaScriptHandler(
                handlerName: 'shortvideo',
                callback: (args) {
                  if (args.length < 2) return null;
                  _ingest(args[1].toString());
                  return null;
                },
              );
            },
            onProgressChanged: (controller, progress) {
              if (!mounted) return;
              setState(() => _progress = progress / 100);
            },
            onLoadStop: (controller, url) {
              if (!mounted || _collecting) return;
              setState(() {
                if (_status.startsWith('正在')) _status = '页面已加载';
              });
            },
            onReceivedError: (controller, request, error) {
              if (!mounted || request.isForMainFrame != true) return;
              setState(() => _status = '网页加载失败：${error.description}');
            },
          ),
        ),
      ),
      bottomNavigationBar: _controlBar(),
    );
  }

  Widget _controlBar() {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
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
                      onPressed: _collecting ? _stop : _start,
                      icon: Icon(_collecting ? Icons.stop : Icons.download),
                      label: Text(_collecting ? '停止抓取' : '开始抓取'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => Get.back(),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 包住 `fetch` / `XMLHttpRequest`，凡是返回体里带平台特征字段的都回传原生。
///
/// 顺带把 `window.open` 和 `target="_blank"` 改成本页跳转：WKWebView 不实现
/// `onCreateWindow` 时新窗口一律是 `null`，抖音右上角「登录」点了没反应就是这个。
String _hookJs(ShortVideoPlatform platform) {
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
      window.flutter_inappwebview.callHandler('shortvideo', String(url), text);
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

  window.open = function (url) {
    try {
      if (url && String(url).indexOf('http') === 0) {
        window.location.href = String(url);
      }
    } catch (e) {}
    return window;
  };

  document.addEventListener('click', function (event) {
    try {
      var node = event.target;
      while (node && node.tagName !== 'A') { node = node.parentElement; }
      if (!node) { return; }
      var target = (node.getAttribute('target') || '').toLowerCase();
      var href = node.getAttribute('href') || '';
      if (target === '_blank' && href.indexOf('http') === 0) {
        event.preventDefault();
        window.location.href = href;
      }
    } catch (e) {}
  }, true);
})();
''';
}

/// 自动点开「收藏」tab，并持续滚到底，让列表继续分页。
String _driverJs(ShortVideoPlatform platform) {
  final titles = platform.tabTitles.map((e) => "'$e'").join(',');
  return '''
(function () {
  if (window.__kumoneDriver) { return; }
  var TITLES = [$titles];
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
      }
      window.scrollTo(0, document.body.scrollHeight);
    } catch (e) {}
  }, 1200);
})();
''';
}