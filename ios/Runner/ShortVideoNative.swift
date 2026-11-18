import Foundation
import UIKit
import WebKit
import Flutter

// 抖音 / TikTok 的原生能力层。
//
// 代码来自旧树 `ci-snapshot-build/ios/Runner/AppDelegate.swift`（在 6S 上真机
// 验证过的那一份），按功能块原样移植，只去掉与产品无关的自装卸和 QA 埋点。
//
// 为什么必须移植：`lib/pages/douyin/*.dart` 依赖 `piliplus/shortvideo_web`
// 这个 MethodChannel 做四件事——网页登录、抓收藏、重新解析直链、原生下载。
// 重建到 2.2.1 基线时只搬了 Dart 层，原生这一侧漏了，通道根本不存在，于是：
//
//   * 「打开网页 / 抓取」点下去没有任何反应（open 无实现）；
//   * 收藏里存的是签名直链，几小时就过期。兜底的 resolvePlayUrl 不存在，
//     只能拿过期地址去播 —— 等很久，或者只有声音没有画面；
//   * cookies 拿不到，本地缓存明明命中也要先等这一步，拖慢开播；
//   * 原生下载不可用，缓存进度和「缓存到本地」都是假的。
//
// 也就是说：播放页那些「点不动 / 慢 / 没声音没画面」的表象，根因在这里。

/// 抖音 / TikTok 收藏的抓取网页。
///
/// 走原生 WKWebView 而不是 flutter_inappwebview：后者是 Flutter 的 platform view，
/// 在这套 iOS 构建里创建出来只有一片白（连页面都不渲染）。原生这边和 Kumone 用的是
/// 同一套代码路径，已经在真机上验证可用。
final class ShortVideoWebViewPlugin: NSObject, FlutterPlugin {
  static let channelName = "piliplus/shortvideo_web"

  private let channel: FlutterMethodChannel
  private var webController: ShortVideoWebViewController?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = ShortVideoWebViewPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "缺少参数", details: nil))
        return
      }
      if present(args: args) {
        result(nil)
      } else {
        result(FlutterError(
          code: "no_presenter",
          message: "找不到可用的窗口，无法打开网页",
          details: nil
        ))
      }
    case "close":
      webController?.closeSelf()
      result(nil)
    case "start":
      webController?.startCollecting()
      result(nil)
    case "stop":
      webController?.stopCollecting()
      result(nil)
    case "cookies":
      // 抖音 / TikTok 的 CDN 会按网页会话校验：Kumone 用 URLSession 下载时
      // 自动带上了 WKWebView 存在 HTTPCookieStorage 里的 cookie，而 Dart 的
      // HttpClient 是独立 cookie 罐，一个都不带——这就是「Kumone 下得动、
      // PiliPlus 0%」的根因。这里把网页的 cookie 交出去。
      let needle = (call.arguments as? [String: Any])?["domain"] as? String ?? ""
      WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
        let list: [[String: String]] = cookies.compactMap { cookie in
          if !needle.isEmpty, !cookie.domain.contains(needle) { return nil }
          return [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
          ]
        }
        DispatchQueue.main.async { result(list) }
      }
    case "deviceMemory":
      // 设备物理内存（字节）。Dart 侧据此决定短视频走不走「低内存」那套策略
      // （串行下载、缓存上限更小、解码缓冲压到最低）——6S 这类 2GB 机器顶不住。
      result(Int(ProcessInfo.processInfo.physicalMemory))
    case "resolvePlayUrl":
      // 收藏里存的直链带签名，过几个小时就 403（TikTok 必过期）。这里用一个
      // 离屏 WKWebView 打开视频页，从页面自带的 JSON 里把新直链抠出来——
      // 和用户在浏览器里打开同一条视频走的是同一条路径。
      let args = call.arguments as? [String: Any] ?? [:]
      let videoId = args["videoId"] as? String ?? ""
      guard !videoId.isEmpty else {
        result(nil)
        return
      }
      ShortVideoPlayResolver(
        videoId: videoId,
        platform: args["platform"] as? String ?? "tiktok",
        userAgent: args["userAgent"] as? String ?? ""
      ) { url in
        DispatchQueue.main.async { result(url) }
      }.start()
    case "download":
      // TikTok 的 CDN 按网页会话校验：Dart 的 HttpClient 一个 cookie 都不带。
      // 用 URLSession 并把 WKWebView 的 cookie 显式塞进请求头，这条路径和
      // Kumone 真机上验证过的一致。
      let args = call.arguments as? [String: Any] ?? [:]
      let id = args["id"] as? Int ?? 0
      let urls = args["urls"] as? [String] ?? []
      let dest = args["destPath"] as? String ?? ""
      guard !urls.isEmpty, !dest.isEmpty else {
        result(["error": "缺少下载参数"])
        return
      }
      let downloader = ShortVideoNativeDownloader(
        urls: urls,
        destPath: dest,
        userAgent: args["userAgent"] as? String ?? "",
        referer: args["referer"] as? String ?? "",
        cookieDomain: args["cookieDomain"] as? String ?? "",
        progress: { [weak self] value in
          DispatchQueue.main.async {
            self?.channel.invokeMethod(
              "downloadProgress",
              arguments: ["id": id, "progress": value]
            )
          }
        }
      ) { path, error in
        DispatchQueue.main.async {
          if let path = path {
            result(["path": path])
          } else {
            result(["error": error ?? "下载失败"])
          }
        }
      }
      downloader.start()
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func present(args: [String: Any]) -> Bool {
    guard let root = Self.topViewController() else {
      NSLog("[ShortVideoWeb] no top view controller")
      return false
    }
    let controller = ShortVideoWebViewController(args: args) { [weak self] method, payload in
      self?.channel.invokeMethod(method, arguments: payload)
    }
    webController = controller
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .fullScreen
    navigation.view.backgroundColor = .systemBackground
    root.present(navigation, animated: true)
    NSLog("[ShortVideoWeb] presented from \(type(of: root))")
    return true
  }

  private static func topViewController() -> UIViewController? {
    var root: UIViewController?
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for window in windowScene.windows where window.isKeyWindow {
        root = window.rootViewController
        break
      }
      if root != nil { break }
    }
    if root == nil {
      root = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
    }
    if root == nil {
      root = UIApplication.shared.windows.first?.rootViewController
    }
    var top = root
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

final class ShortVideoWebViewController: UIViewController {
  private let args: [String: Any]
  private let emit: (String, Any?) -> Void

  private var webView: WKWebView!
  private let statusLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let hintButton = UIButton(type: .system)
  private lazy var startButton = UIBarButtonItem(
    title: "开始抓取",
    style: .done,
    target: self,
    action: #selector(toggleCollecting)
  )

  private var timer: Timer?
  private var idleRounds = 0
  private var lastCount = 0
  private var received = 0
  private var startedAt = Date()
  private var collecting = false
  private var didNotifyClose = false
  private var hookInstalled = false
  private var pendingStart = false
  private var didFinishLoading = false
  private var reloadingForCollect = false
  private var popup: ShortVideoPopupController?
  private var lastPopupURL = ""
  private var lastPopupAt = Date.distantPast
  /// 登录完成轮询的代号：每次点登录加一，旧的轮询发现代号变了就自己停。
  private var loginWatchGeneration = 0
  /// 这次点登录之后，登录浮层到底有没有出现过。
  private var loginDialogSeen = false

  static func armedHookScript(hookScript: String) -> String {
    """
    (function () {
      var armed = false;
      try { armed = window.localStorage.getItem('__kumoneArm') === '1'; } catch (e) {}
      if (!armed) { return; }
      \(hookScript)
    })();
    """
  }

  /// 常驻的极轻量脚本：只接管 `window.open`。
  static let popupBridgeScript = """
  (function () {
    if (window.__kumonePopupBridge) { return; }
    window.__kumonePopupBridge = true;
    var realOpen = window.open;
    window.open = function (url, name, features) {
      var handle = null;
      try { handle = realOpen.apply(window, arguments); } catch (e) { handle = null; }
      try {
        var target = url ? String(url) : '';
        if (!handle && target && target !== 'about:blank') {
          window.webkit.messageHandlers.shortvideo.postMessage({ popup: target });
        }
      } catch (e) {}
      return handle;
    };
  })();
  """

  private var homeURL: String { args["url"] as? String ?? "https://www.douyin.com/" }
  private var favoritesURL: String { args["favoritesUrl"] as? String ?? homeURL }
  private var loginURL: String { args["loginUrl"] as? String ?? homeURL }
  private var userAgent: String { args["userAgent"] as? String ?? "" }
  private var hookScript: String { args["hookScript"] as? String ?? "" }
  private var driverScript: String { args["driverScript"] as? String ?? "" }
  private var titleText: String { args["title"] as? String ?? "抓取" }

  init(args: [String: Any], emit: @escaping (String, Any?) -> Void) {
    self.args = args
    self.emit = emit
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = titleText
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "关闭",
      style: .plain,
      target: self,
      action: #selector(closeSelf)
    )
    navigationItem.rightBarButtonItems = [
      startButton,
      UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"),
        style: .plain,
        target: self,
        action: #selector(reloadFavorites)
      ),
      UIBarButtonItem(
        image: UIImage(systemName: "person.crop.circle"),
        style: .plain,
        target: self,
        action: #selector(openLogin)
      ),
      UIBarButtonItem(
        image: UIImage(systemName: "safari"),
        style: .plain,
        target: self,
        action: #selector(openInSafari)
      ),
    ]

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.defaultWebpagePreferences.preferredContentMode = .desktop
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    configuration.userContentController.add(self, name: "shortvideo")
    // 只接管 window.open：登录阶段不注入抓取脚本，但弹窗被 WebKit 拦掉时
    // 连 delegate 都不回调，点了「登录」就是一点反应都没有。
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: ShortVideoWebViewController.popupBridgeScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    // 只有点「开始抓取」之后（localStorage 标记为 1）才会真正装监听：
    // 接口请求必须发生在监听装好之后，否则页面早就把收藏拉完了，一段都收不到。
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: ShortVideoWebViewController.armedHookScript(
          hookScript: args["hookScript"] as? String ?? ""
        ),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
    )

    let web = WKWebView(frame: .zero, configuration: configuration)
    web.customUserAgent = userAgent
    web.navigationDelegate = self
    web.uiDelegate = self
    web.allowsBackForwardNavigationGestures = true
    web.isOpaque = true
    web.backgroundColor = .white
    web.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(web)

    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabel
    statusLabel.numberOfLines = 3
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(statusLabel)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)

    hintButton.setTitle("网页空白？点这里重试", for: .normal)
    hintButton.titleLabel?.font = .systemFont(ofSize: 12)
    hintButton.translatesAutoresizingMaskIntoConstraints = false
    hintButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
    hintButton.isHidden = true
    view.addSubview(hintButton)

    NSLayoutConstraint.activate([
      web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      web.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      statusLabel.bottomAnchor.constraint(
        equalTo: hintButton.topAnchor,
        constant: -4
      ),
      hintButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      hintButton.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor,
        constant: -8
      ),
      spinner.centerXAnchor.constraint(equalTo: web.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: web.centerYAnchor),
    ])

    webView = web
    load(homeURL)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    stopTimer()
    if !didNotifyClose {
      didNotifyClose = true
      emit("closed", nil)
    }
  }

  // MARK: - Actions

  @objc func closeSelf() {
    stopTimer()
    dismiss(animated: true)
  }

  @objc private func reloadFavorites() {
    load(favoritesURL)
  }

  /// 打开登录。
  ///
  /// 直接 `load(loginURL)` 是不行的：`sso.douyin.com` 只是一个登录落地页，
  /// 登录浮层必须由 `www.douyin.com` 自己的前端拉起来，才有回调可以把 cookie
  /// 写进 douyin.com 域。卸载重装后 WKWebView 的 data store 是空的，未登录的
  /// 抖音首页会把侧栏「我的」和头像入口做成点不动的样式，用户于是「根本没有登录
  /// 入口」。这里改成：先在当前页面里用 JS 点官方登录按钮，点不到再退回 SSO。
  @objc private func openLogin() {
    let script = ShortVideoWebViewController.loginTriggerScript
    webView.evaluateJavaScript(script) { [weak self] result, error in
      guard let self else { return }
      if error == nil, ShortVideoWebViewController.truthy(result) {
        self.setStatus("已调出登录浮层，扫码或手机号登录后等待自动刷新…")
        self.watchLoginCompletion()
        return
      }
      // 页面没渲染登录按钮（还没加载完、或站点改版）：退回站点自己的登录页。
      self.load(self.loginURL)
    }
  }

  /// `evaluateJavaScript` 把 JS 布尔桥接成 NSNumber 而不是 Bool，
  /// 直接 `as? Bool` 会永远失败，于是每次都被当成「没点到」退回 SSO。
  static func truthy(_ value: Any?) -> Bool {
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number.boolValue }
    return false
  }

  /// 等登录完成，然后刷新当前页把登录态带进来。
  ///
  /// 抖音的登录浮层是前端自己管理的，登录完不会整页跳转，cookie 虽然写进了
  /// douyin.com 域，但当前页面上的旧渲染还是未登录状态；不刷新就抓不到收藏。
  private func watchLoginCompletion() {
    loginWatchGeneration += 1
    loginDialogSeen = false
    let generation = loginWatchGeneration
    pollLoginState(generation: generation, attempt: 0)
  }

  private func pollLoginState(generation: Int, attempt: Int) {
    guard generation == loginWatchGeneration, attempt < 60 else { return }
    let probe = """
    (function () {
      var dialog = document.querySelector(
        '[class*=login-container], [class*=loginModal], [id*=login-modal]'
      );
      var dialogVisible = false;
      if (dialog) {
        var style = window.getComputedStyle(dialog);
        var rect = dialog.getBoundingClientRect();
        dialogVisible = style.display !== 'none'
          && style.visibility !== 'hidden'
          && rect.width > 0
          && rect.height > 0;
      }
      var avatar = document.querySelector(
        '[data-e2e*=user-info], [class*=userInfo], [class*=avatar]'
      );
      // seen 用来区分「登录浮层出现过又关掉」和「压根没弹出浮层」：
      // 未登录页面上也有 avatar 节点，只看它会一开头就误判成已登录。
      return { visible: dialogVisible, seen: !!dialog, avatar: !!avatar };
    })();
    """
    webView.evaluateJavaScript(probe) { [weak self] result, _ in
      guard let self, generation == self.loginWatchGeneration else { return }
      let map = result as? [String: Any] ?? [:]
      let visible = ShortVideoWebViewController.truthy(map["visible"])
      let seen = ShortVideoWebViewController.truthy(map["seen"])
      let avatar = ShortVideoWebViewController.truthy(map["avatar"])
      if seen { self.loginDialogSeen = true }
      // 判定登录完成：浮层曾出现过、现在已关闭，且页面上出现了登录态节点。
      if self.loginDialogSeen && !visible && avatar {
        self.loginWatchGeneration += 1
        self.setStatus("登录成功，正在刷新页面…")
        self.webView.reload()
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        self.pollLoginState(generation: generation, attempt: attempt + 1)
      }
    }
  }

  /// 在当前页面里找官方登录入口并点一下。
  ///
  /// 顺序：抖音头部的「登录」按钮 → 侧栏「我的」→ TikTok 的 log in 链接。
  /// 返回 true 表示点到了至少一个候选元素。
  static let loginTriggerScript: String = """
  (function () {
    var texts = ['登录', '立即登录', 'Log in', 'Log in to TikTok', '登录/注册'];
    var nodes = document.querySelectorAll(
      'button, a, div[role=button], [data-e2e*=login], [class*=login]'
    );
    var hit = 0;
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var t = (el.innerText || el.textContent || '').trim();
      if (t.length === 0 || t.length > 12) { continue; }
      for (var j = 0; j < texts.length; j++) {
        if (t === texts[j] || t.indexOf(texts[j]) === 0) {
          var r = el.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) { continue; }
          el.click();
          hit = hit + 1;
          break;
        }
      }
      if (hit > 0) { break; }
    }
    if (hit === 0) {
      // 兜底：站点常把登录入口挂在 avatar / 个人中心上。
      var avatar = document.querySelector(
        '[data-e2e*=avatar], [class*=avatar], [class*=Avatar]'
      );
      if (avatar) { avatar.click(); hit = hit + 1; }
    }
    return hit > 0;
  })();
  """

  /// 开一个真正的弹窗，别把站点自己的页面冲掉。
  private func presentPopup(_ url: URL) {
    let scheme = (url.scheme ?? "").lowercased()
    guard scheme == "http" || scheme == "https" else { return }
    let signature = url.absoluteString
    if signature == lastPopupURL, Date().timeIntervalSince(lastPopupAt) < 3 {
      return
    }
    lastPopupURL = signature
    lastPopupAt = Date()

    // 弹窗已经开着的时候以前是直接 return：抖音登录先弹扫码再转手机号，
    // 第二次 window.open 就被静默吞掉，用户感觉「点了完全没反应」。
    // 现在改成让已有弹窗自己跳过去，而不是丢弃这次导航。
    if let existing = popup {
      existing.load(url)
      return
    }

    let controller = ShortVideoPopupController(url: url, userAgent: userAgent) {
      [weak self] in
      guard let self else { return }
      self.popup = nil
      self.setStatus("登录窗口已关闭，刷新本页…")
      self.webView.reload()
    }
    popup = controller
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .fullScreen
    present(navigation, animated: true)
  }

  @objc private func openInSafari() {
    guard let url = webView.url ?? URL(string: homeURL) else { return }
    UIApplication.shared.open(url)
  }

  @objc private func retry() {
    hintButton.isHidden = true
    didFinishLoading = false
    load(webView.url?.absoluteString ?? homeURL)
  }

  @objc private func toggleCollecting() {
    if collecting {
      stopCollecting(message: "已停止，收到 \(received) 段数据")
    } else {
      startCollecting()
    }
  }

  private func load(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    webView.customUserAgent = userAgent
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    webView.load(request)
    didFinishLoading = false
    spinner.startAnimating()
    setStatus("正在打开 \(urlString)…")
    scheduleBlankCheck()
  }

  /// 10 秒还没渲染出内容就提示一下——比一片白什么都不说要好排查。
  private func scheduleBlankCheck() {
    hintButton.isHidden = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self, !self.didFinishLoading else { return }
      self.hintButton.isHidden = false
      self.spinner.stopAnimating()
    }
  }

  func startCollecting() {
    guard !collecting else { return }
    if !isOnFavoritesPage {
      pendingStart = true
      load(favoritesURL)
      setStatus("正在打开收藏页，加载完自动开始抓取…")
      return
    }
    beginCollecting()
  }

  private var isOnFavoritesPage: Bool {
    guard let current = webView.url?.absoluteString else { return false }
    if favoritesURL.contains("/user/self") {
      return current.contains("/user/self") || current.contains("showTab=favorite")
    }
    if favoritesURL.contains("tiktok.com/@") {
      return current.contains("tiktok.com/@")
    }
    return current.contains(favoritesURL)
  }

  private func beginCollecting() {
    collecting = true
    startButton.title = "停止抓取"
    idleRounds = 0
    lastCount = received
    startedAt = Date()
    received = 0
    setStatus("正在抓取…正在重新加载页面，让收藏接口重新请求一次")
    // 接口请求必须发生在监听装好之后。以前在加载完的页面上补装监听，
    // 页面早把收藏拉过了，于是永远收到 0 段——TikTok 收藏页是整页渲染，
    // 切 tab 也不会再发请求，一条都抓不到。现在：置标记 → reload →
    // documentStart 按标记自动装监听 → 页面自己重新请求。
    let js = "try{localStorage.setItem('__kumoneArm','1');}catch(e){}"
    webView.evaluateJavaScript(js) { [weak self] _, _ in
      guard let self else { return }
      self.hookInstalled = true
      self.reloadingForCollect = true
      self.webView.reload()
    }
  }

  /// 只在抓取时才注入：登录 / 搜索阶段页面是干净的，不会被影响。
  private func installHook(_ completion: @escaping () -> Void) {
    guard !hookInstalled else { completion(); return }
    webView.evaluateJavaScript(hookScript) { [weak self] _, _ in
      self?.hookInstalled = true
      completion()
    }
  }

  func stopCollecting(message: String? = nil) {
    guard collecting else { return }
    collecting = false
    startButton.title = "开始抓取"
    stopTimer()
    webView.evaluateJavaScript(
      "try{clearInterval(window.__kumoneDriver);window.__kumoneDriver=null;"
      + "localStorage.setItem('__kumoneArm','0');}catch(e){}"
    )
    setStatus(message ?? "已停止，收到 \(received) 段数据")
  }

  private func startTimer() {
    stopTimer()
    timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    guard collecting else { return }
    webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")
    if Date().timeIntervalSince(startedAt) > 300 {
      stopCollecting(message: "抓取超时，收到 \(received) 段数据")
      return
    }
    if received == lastCount {
      idleRounds += 1
    } else {
      idleRounds = 0
      lastCount = received
    }
    if idleRounds >= 10 {
      stopCollecting(message: "抓取完成，收到 \(received) 段数据")
    }
  }

  private func setStatus(_ text: String) {
    statusLabel.text = text
    emit("status", text)
  }
}

extension ShortVideoWebViewController: WKScriptMessageHandler {
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "shortvideo",
          let payload = message.body as? [String: Any] else { return }

    if let popup = payload["popup"] as? String,
       let url = URL(string: popup) {
      presentPopup(url)
      return
    }

    guard let body = payload["body"] as? String else { return }
    received += 1
    emit("payload", ["body": body])
    if collecting {
      statusLabel.text = "收到 \(received) 段数据…"
    }
  }
}

extension ShortVideoWebViewController: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    didStartProvisionalNavigation navigation: WKNavigation!
  ) {
    hookInstalled = false
    spinner.startAnimating()
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    didFinishLoading = true
    spinner.stopAnimating()
    hintButton.isHidden = true
    if !collecting {
      setStatus("页面已响应：\(webView.url?.absoluteString.prefix(60) ?? "")")
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    didFinishLoading = true
    spinner.stopAnimating()
    hintButton.isHidden = true
    if pendingStart {
      pendingStart = false
      beginCollecting()
      return
    }
    if reloadingForCollect {
      reloadingForCollect = false
      webView.evaluateJavaScript(driverScript)
      startTimer()
      return
    }
    if !collecting {
      setStatus("页面已加载：登录后点右上角「开始抓取」")
    }
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    report(error)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    report(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    spinner.stopAnimating()
    hintButton.isHidden = false
    setStatus("网页进程被系统回收，点「重试」或右上角刷新")
  }

  private func report(_ error: Error) {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
    spinner.stopAnimating()
    hintButton.isHidden = false
    setStatus("网页加载失败：\(error.localizedDescription)（\(ns.code)）")
  }
}

extension ShortVideoWebViewController: WKUIDelegate {
  /// `window.open` / `target=_blank` 单独弹一层窗口。
  ///
  /// 以前是「塞回本页加载」，结果把站点自己的 SPA 冲掉——表现就是
  /// 「二维码刚要出来又闪回首页」，登录永远做不成。现在开一个真正的弹窗，
  /// cookie 落在同一个域上，关掉弹窗本页刷新一下就是登录态。
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url {
      presentPopup(url)
    }
    return nil
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping () -> Void
  ) {
    completionHandler()
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}

/// `window.open` 弹出来的登录窗。
///
/// 抖音 / TikTok 的二维码登录都走新窗口。塞回本页加载会把站点 SPA 冲掉，
/// 所以这里单独开一层；cookie 落在同一个域上，关掉后本页刷新即为登录态。
final class ShortVideoPopupCloseBridge: NSObject, WKScriptMessageHandler {
  var onClose: (() -> Void)?

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "kumoneClose" else { return }
    DispatchQueue.main.async { [weak self] in
      self?.onClose?()
    }
  }
}

final class ShortVideoPopupController: UIViewController, WKNavigationDelegate {
  private let request: URL
  private let userAgent: String
  private let onClose: () -> Void
  private let closeBridge = ShortVideoPopupCloseBridge()
  private var didNotify = false

  private lazy var webView: WKWebView = {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.defaultWebpagePreferences.preferredContentMode = .desktop
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    configuration.userContentController.add(closeBridge, name: "kumoneClose")
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: Self.closeBridgeScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
      )
    )
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.customUserAgent = userAgent
    view.navigationDelegate = self
    view.allowsBackForwardNavigationGestures = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private static let closeBridgeScript = """
  (function () {
    if (window.__kumoneCloseBridge) { return; }
    window.__kumoneCloseBridge = true;
    var realClose = window.close;
    window.close = function () {
      try { window.webkit.messageHandlers.kumoneClose.postMessage({ close: true }); } catch (e) {}
      try { return realClose.apply(window, arguments); } catch (e) {}
    };
  })();
  """

  init(url: URL, userAgent: String, onClose: @escaping () -> Void) {
    self.request = url
    self.userAgent = userAgent
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  /// 已经开着的弹窗改去加载新地址（主页面又发起了一次 window.open）。
  func load(_ url: URL) {
    guard isViewLoaded else { return }
    webView.customUserAgent = userAgent
    webView.load(URLRequest(url: url))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = request.host ?? "登录"
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "关闭",
      style: .done,
      target: self,
      action: #selector(closeSelf)
    )
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"),
        style: .plain,
        target: self,
        action: #selector(reloadSelf)
      ),
      UIBarButtonItem(
        image: UIImage(systemName: "chevron.backward"),
        style: .plain,
        target: self,
        action: #selector(backSelf)
      ),
    ]

    view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    closeBridge.onClose = { [weak self] in
      self?.closeSelf()
    }
    webView.load(URLRequest(url: request, timeoutInterval: 30))
  }

  @objc private func closeSelf() {
    dismiss(animated: true)
  }

  @objc private func reloadSelf() {
    if webView.url == nil {
      webView.load(URLRequest(url: request, timeoutInterval: 30))
    } else {
      webView.reload()
    }
  }

  @objc private func backSelf() {
    if webView.canGoBack {
      webView.goBack()
    } else {
      reloadSelf()
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard !didNotify else { return }
    didNotify = true
    onClose()
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    let scheme = (navigationAction.request.url?.scheme ?? "").lowercased()
    let inApp = scheme.isEmpty
      || scheme == "http"
      || scheme == "https"
      || scheme == "about"
      || scheme == "file"
      || scheme == "data"
      || scheme == "blob"
    if inApp {
      decisionHandler(.allow)
      return
    }
    if let url = navigationAction.request.url,
       UIApplication.shared.canOpenURL(url) {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
    decisionHandler(.cancel)
  }
}

/// 请求头。TikTok 的 CDN 就是按这个会话认人的。
enum ShortVideoCookies {
  static func header(for needle: String, completion: @escaping (String) -> Void) {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let picked = cookies.filter { needle.isEmpty || $0.domain.contains(needle) }
      let header = picked.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      completion(header)
    }
  }
}

/// 用 URLSession 把一条视频整段下下来。
///
/// 不用 Dart 的 HttpClient：它的 cookie 罐是独立的，TikTok 的 CDN 会按网页
/// 会话校验，一个 cookie 都不带就是 403 / 0 字节。这里关掉 URLSession 自己的
/// cookie 存储（否则会被空罐覆盖），改成显式写 `Cookie` 头。
final class ShortVideoNativeDownloader: NSObject, URLSessionDownloadDelegate {
  private let urls: [String]
  private let destPath: String
  private let userAgent: String
  private let referer: String
  private let cookieDomain: String
  private let progressHandler: (Double) -> Void
  private let completion: (String?, String?) -> Void

  private var session: URLSession!
  private var cookie = ""
  private var index = 0
  private var lastError = "没有可用的地址"
  private var moved = false
  private var finished = false

  init(
    urls: [String],
    destPath: String,
    userAgent: String,
    referer: String,
    cookieDomain: String,
    progress: @escaping (Double) -> Void,
    completion: @escaping (String?, String?) -> Void
  ) {
    self.urls = urls
    self.destPath = destPath
    self.userAgent = userAgent
    self.referer = referer
    self.cookieDomain = cookieDomain
    self.progressHandler = progress
    self.completion = completion
    super.init()
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.httpCookieAcceptPolicy = .never
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 120
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  func start() {
    ShortVideoCookies.header(for: cookieDomain) { [weak self] value in
      guard let self = self else { return }
      self.cookie = value
      self.attemptNext()
    }
  }

  private func attemptNext() {
    if finished { return }
    guard index < urls.count else {
      finish(nil, lastError)
      return
    }
    let raw = urls[index]
    index += 1
    guard let url = URL(string: raw), url.scheme != nil else {
      lastError = "地址无效"
      attemptNext()
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    if !userAgent.isEmpty {
      request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }
    if !referer.isEmpty {
      request.setValue(referer, forHTTPHeaderField: "Referer")
    }
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9,zh-CN;q=0.8", forHTTPHeaderField: "Accept-Language")
    request.setValue("bytes=0-", forHTTPHeaderField: "Range")
    if !cookie.isEmpty {
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
    moved = false
    lastError = ""
    session.downloadTask(with: request).resume()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    progressHandler(min(0.999, max(0, value)))
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let http = downloadTask.response as? HTTPURLResponse else {
      lastError = "没有响应"
      return
    }
    let status = http.statusCode
    let mime = (http.mimeType ?? "").lowercased()
    guard status == 200 || status == 206 else {
      lastError = "HTTP \(status)"
      return
    }
    if mime.contains("html") || mime.contains("json") || mime.contains("text/") {
      lastError = "返回的是网页不是视频（\(mime)）"
      return
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: location.path)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    guard size > 16 * 1024 else {
      lastError = "只有 \(size) 字节"
      return
    }
    do {
      let dir = (destPath as NSString).deletingLastPathComponent
      if !dir.isEmpty {
        try? FileManager.default.createDirectory(
          atPath: dir,
          withIntermediateDirectories: true
        )
      }
      try? FileManager.default.removeItem(atPath: destPath)
      try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: destPath))
      moved = true
      progressHandler(1)
    } catch {
      lastError = "写入失败：\(error.localizedDescription)"
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if moved {
      finish(destPath, nil)
      return
    }
    let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
    if let error = error {
      lastError = status > 0
        ? "HTTP \(status) / \(error.localizedDescription)"
        : error.localizedDescription
    } else if lastError.isEmpty {
      lastError = status > 0 ? "HTTP \(status)" : "未知错误"
    }
    attemptNext()
  }

  private func finish(_ path: String?, _ error: String?) {
    if finished { return }
    finished = true
    session.invalidateAndCancel()
    session = nil
    completion(path, error)
  }
}

// MARK: - 短视频：过期直链重解析

/// 用离屏 WKWebView 打开视频页，从页面自带的 JSON 里取一条新直链。
///
/// TikTok 网页把整条视频的数据塞在 `__UNIVERSAL_DATA_FOR_REHYDRATION__`
/// 这个 script 里（抖音在 `_ROUTER_DATA` 里）；不依赖具体结构，直接把所有
/// 长得像 CDN 地址的字符串捞出来。
final class ShortVideoPlayResolver: NSObject {
  private let videoId: String
  private let platform: String
  private let userAgent: String
  private let completion: (String?) -> Void
  private var webView: WKWebView?
  private var timer: Timer?
  private var ticks = 0
  private var candidate = 0
  private var finished = false

  init(
    videoId: String,
    platform: String,
    userAgent: String,
    completion: @escaping (String?) -> Void
  ) {
    self.videoId = videoId
    self.platform = platform
    self.userAgent = userAgent
    self.completion = completion
    super.init()
  }

  func start() {
    // TikTok 的 embed 页是服务端直出的，先用一次轻量 HTTP 试试：2G 内存的
    // 6s 上能省掉一整个 WKWebView。失败再退回 WebView。
    if platform == "tiktok" {
      prefetch()
      return
    }
    startWebView()
  }

  private func pages() -> [String] {
    if platform == "douyin" {
      return ["https://www.douyin.com/video/\(videoId)"]
    }
    return [
      "https://www.tiktok.com/embed/v2/\(videoId)",
      "https://www.tiktok.com/@i/video/\(videoId)",
      "https://m.tiktok.com/v/\(videoId).html",
    ]
  }

  private func prefetch() {
    guard let url = URL(string: pages()[0]) else {
      startWebView()
      return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 8
    request.setValue(
      userAgent.isEmpty
        ? "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1"
        : userAgent,
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("https://www.tiktok.com/", forHTTPHeaderField: "Referer")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    let task = URLSession.shared.dataTask(with: request) { [self] data, _, _ in
      var found: String?
      if let data = data, data.count > 1024, data.count < 4_000_000,
         let text = String(data: data, encoding: .utf8) {
        found = ShortVideoPlayResolver.pick(text)
      }
      DispatchQueue.main.async {
        guard !self.finished else { return }
        if let found = found {
          self.finish(found)
        } else {
          self.startWebView()
        }
      }
    }
    task.resume()
  }

  private func startWebView() {
    guard !finished else { return }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.defaultWebpagePreferences.preferredContentMode = .desktop
    let web = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 390, height: 844),
      configuration: config
    )
    if !userAgent.isEmpty {
      web.customUserAgent = userAgent
    }
    webView = web
    candidate = 0
    if let url = URL(string: pages()[0]) {
      web.load(URLRequest(url: url))
    }
    let ticker = Timer(timeInterval: 0.9, repeats: true) { [self] _ in
      self.poll()
    }
    RunLoop.main.add(ticker, forMode: .common)
    timer = ticker
  }

  private func poll() {
    guard !finished, let web = webView else { return }
    ticks += 1
    // 约 18 秒还没捞到就放弃，别把播放卡住。
    if ticks > 20 {
      finish(nil)
      return
    }
    // 第 7 / 13 个 tick 依次换下一个候选页：embed → 主页 → 移动版。
    if ticks == 7 || ticks == 13 {
      let list = pages()
      let next = candidate + 1
      if next < list.count {
        candidate = next
        if let url = URL(string: list[next]) {
          web.load(URLRequest(url: url))
        }
        return
      }
    }
    let js = """
    (function () {
      var el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
      if (el && el.textContent) { return el.textContent; }
      var other = document.getElementById('_ROUTER_DATA');
      if (other && other.textContent) { return other.textContent; }
      var html = document.documentElement ? document.documentElement.innerHTML : '';
      return html.length > 900000 ? html.substring(0, 900000) : html;
    })()
    """
    web.evaluateJavaScript(js) { [self] value, _ in
      guard !self.finished else { return }
      guard let text = value as? String, text.count > 200 else { return }
      if let url = ShortVideoPlayResolver.pick(text) {
        self.finish(url)
      }
    }
  }

  private func finish(_ url: String?) {
    if finished { return }
    finished = true
    timer?.invalidate()
    timer = nil
    webView?.stopLoading()
    webView = nil
    completion(url)
  }

  /// 在页面 JSON 里挑一条能直接下的地址。
  static func pick(_ text: String) -> String? {
    var fallback: String?
    for raw in text.split(separator: "\"") {
      guard raw.contains("http") else { continue }
      let token = unescape(String(raw))
      guard token.hasPrefix("http") else { continue }
      guard token.contains("/video/tos/")
        || token.contains("aweme/v1/play/")
        || token.contains("douyinvod") else { continue }
      if token.contains("mime_type=video_mp4") { return token }
      if fallback == nil { fallback = token }
    }
    return fallback
  }

  /// JSON 里的 `\/`、`\u002F`、`\u0026` 都要还原，否则地址是坏的。
  static func unescape(_ input: String) -> String {
    if !input.contains("\\") {
      return input
    }
    var output = ""
    var index = input.startIndex
    while index < input.endIndex {
      let char = input[index]
      if char == "\\",
         let next = input.index(index, offsetBy: 1, limitedBy: input.endIndex),
         next < input.endIndex {
        if input[next] == "/" {
          output.append("/")
          index = input.index(after: next)
          continue
        }
        if input[next] == "u",
           let end = input.index(index, offsetBy: 6, limitedBy: input.endIndex) {
          let hex = String(input[input.index(index, offsetBy: 2)..<end])
          if hex.count == 4,
             let code = UInt32(hex, radix: 16),
             let scalar = Unicode.Scalar(code) {
            output.append(Character(scalar))
            index = end
            continue
          }
        }
      }
      output.append(char)
      index = input.index(after: index)
    }
    return output
  }
}
