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
        result(["url": "", "reason": "notfound"])
        return
      }
      ShortVideoPlayResolver(
        videoId: videoId,
        platform: args["platform"] as? String ?? "tiktok",
        userAgent: args["userAgent"] as? String ?? ""
      ) { url, reason in
        DispatchQueue.main.async {
          result(["url": url ?? "", "reason": reason])
        }
      }.start()
    case "resolveComments":
      // 收藏接口只回视频元数据，评论要回视频页里拿。这里开一个离屏 WKWebView，
      // 注入只关心评论列表的 hook，页面自己发出的评论请求会被截下来。
      // 最多等 12 秒；取不到就回空，Dart 侧给「无评论 / 失败」提示和网页入口。
      let commentArgs = call.arguments as? [String: Any] ?? [:]
      let commentVideoId = commentArgs["videoId"] as? String ?? ""
      guard !commentVideoId.isEmpty else {
        result(["comments": [], "reason": "notfound"])
        return
      }
      let limit = commentArgs["limit"] as? Int ?? 40
      ShortVideoCommentResolver(
        videoId: commentVideoId,
        platform: commentArgs["platform"] as? String ?? "douyin",
        userAgent: commentArgs["userAgent"] as? String ?? "",
        limit: max(1, min(limit, 80))
      ) { comments, reason in
        DispatchQueue.main.async {
          result(["comments": comments, "reason": reason])
        }
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
  /// 点登录的这次尝试：1.5s 兜底加载和 8s 慢加载提示都靠它判定是否过期。
  private var loginAttemptGeneration = 0
  /// 这次登录是否已经成功；成功后不再触发兜底加载 / 慢加载提示。
  private var loginSucceeded = false
  /// 兜底登录地址是否已加载过，避免 1.5s 检查重复整页 load。
  private var loginFallbackLoaded = false
  /// 兜底地址加载完后又点过一次官方登录入口，避免反复 reload 兜底页。
  private var loginFallbackClicked = false
  /// 页面加载完后探测登录态的代号：旧的回调不能覆盖新页面的提示。
  private var loginStateProbeGeneration = 0

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
  /// 确定能拉起登录 UI 的地址：抖音的浮层只有 www.douyin.com 前端会拉起，
  /// TikTok 则直接用自己的 /login 页。Dart 侧可以显式传，没传就按站点推断。
  private var loginFallbackURL: String {
    if let explicit = args["loginFallbackUrl"] as? String, !explicit.isEmpty {
      return explicit
    }
    if loginURL.contains("douyin") {
      if homeURL.contains("douyin.com") { return homeURL }
      return "https://www.douyin.com/"
    }
    if loginURL.contains("tiktok") { return "https://www.tiktok.com/login" }
    return homeURL
  }
  private var cookieDomainNeedle: String {
    if let explicit = args["cookieDomain"] as? String, !explicit.isEmpty {
      return explicit
    }
    if homeURL.contains("douyin") { return "douyin.com" }
    if homeURL.contains("tiktok") { return "tiktok.com" }
    return ""
  }
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
  /// 入口」。这里改成：先在当前页面里用 JS 点官方登录按钮；1.5s 内没看到登录
  /// 浮层就 load 一个确定能拉起登录 UI 的地址；8s 仍没有任何登录界面就明确提示。
  @objc private func openLogin() {
    // 顺序：JS 点官方登录入口 → 1.5s 确认浮层可见 → 不可见就 load 兜底
    // 地址；8s 还没有任何登录 UI 就明确提示，避免用户一直干等。
    loginAttemptGeneration += 1
    let generation = loginAttemptGeneration
    loginDialogSeen = false
    loginSucceeded = false
    loginFallbackLoaded = false
    loginFallbackClicked = false
    setStatus("正在打开登录…")
    let script = ShortVideoWebViewController.loginTriggerScript
    watchLoginCompletion()
    scheduleSlowLoginHint(generation: generation)
    webView.evaluateJavaScript(script) { [weak self] result, error in
      guard let self, generation == self.loginAttemptGeneration,
            !self.loginSucceeded else { return }
      if error == nil, ShortVideoWebViewController.truthy(result) {
        self.setStatus("已调出登录浮层，扫码或手机号登录后等待自动刷新…")
        self.scheduleLoginConfirm(generation: generation)
        return
      }
      // 点了但浮层不一定真的出来，1.5s 后再确认；仍没有就 load 兜底地址。
      self.scheduleLoginConfirm(generation: generation)
    }
  }

  /// 1.5s 后确认登录 UI 到底出没出现；没出现就直接 load 兜底地址。
  private func scheduleLoginConfirm(generation: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.confirmLoginVisible(generation: generation)
    }
  }

  private func confirmLoginVisible(generation: Int) {
    guard generation == loginAttemptGeneration, !loginSucceeded else { return }
    let current = (webView.url?.absoluteString ?? "").lowercased()
    if current.contains("login") || current.contains("sso") {
      loginDialogSeen = true
      hintButton.isHidden = true
      setStatus("已打开登录页，登录后会自动刷新…")
      return
    }
    webView.evaluateJavaScript(ShortVideoWebViewController.loginVisibleProbe) {
      [weak self] result, _ in
      guard let self, generation == self.loginAttemptGeneration,
            !self.loginSucceeded else { return }
      let map = result as? [String: Any] ?? [:]
      if ShortVideoWebViewController.truthy(map["visible"]) {
        self.loginDialogSeen = true
        self.hintButton.isHidden = true
        self.setStatus("已调出登录界面，扫码或手机号登录后会自动刷新…")
        return
      }
      guard !self.loginFallbackLoaded else {
        // 兜底页已经加载并又点过一次入口，浮层还是没出来：别再整页 load。
        self.setStatus("仍未看到登录界面，可点右上角刷新或在 Safari 打开")
        self.hintButton.isHidden = false
        return
      }
      self.loginFallbackLoaded = true
      self.setStatus("没有调到登录浮层，正在直接打开登录页…")
      self.load(self.loginFallbackURL)
    }
  }

  /// 点登录 8s 后既没看到浮层、也没跳到登录页：明确提示，别让用户干等。
  private func scheduleSlowLoginHint(generation: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
      guard let self, generation == self.loginAttemptGeneration,
            !self.loginSucceeded else { return }
      if self.loginDialogSeen { return }
      let current = (self.webView.url?.absoluteString ?? "").lowercased()
      if current.contains("login") || current.contains("sso") { return }
      // 兜底 load 之后浮层可能晚一点才出来，先再探一次再决定要不要提示。
      self.webView.evaluateJavaScript(
        ShortVideoWebViewController.loginVisibleProbe
      ) { [weak self] result, _ in
        guard let self, generation == self.loginAttemptGeneration,
              !self.loginSucceeded else { return }
        let map = result as? [String: Any] ?? [:]
        if ShortVideoWebViewController.truthy(map["visible"]) {
          self.loginDialogSeen = true
          self.setStatus("已调出登录界面，扫码或手机号登录后会自动刷新…")
          return
        }
        self.setStatus("加载较慢，可点右上角刷新或在 Safari 打开")
        self.hintButton.isHidden = false
      }
    }
  }

  /// `evaluateJavaScript` 把 JS 布尔桥接成 NSNumber 而不是 Bool，
  /// 直接 `as? Bool` 会永远失败，于是每次都被当成「没点到」退回 SSO。
  static func truthy(_ value: Any?) -> Bool {
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number.boolValue }
    return false
  }

  /// 1.5s 兜底判断和轮询共用：只认真正可见的登录浮层。
  static let loginVisibleProbe: String = """
  (function () {
    function visible(el) {
      if (!el) { return false; }
      var style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden') { return false; }
      var rect = el.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) { return false; }
      var opacity = parseFloat(style.opacity || '1');
      return !(opacity < 0.05);
    }
    var selector = '[class*=login-container], [class*=loginModal], '
      + '[class*=login-modal], [id*=login-modal], [id*=login-panel], '
      + '[class*=LoginModal], [data-e2e=login-modal], [class*=TUXModal]';
    var dialog = document.querySelector(selector);
    if (visible(dialog)) { return { visible: true, seen: true }; }
    var dialogs = document.querySelectorAll('[role=dialog]');
    for (var i = 0; i < dialogs.length; i++) {
      var text = (dialogs[i].innerText || dialogs[i].textContent || '');
      if (text.length > 0
          && /登录|扫码|手机号|Log in|Sign up/i.test(text)
          && visible(dialogs[i])) {
        return { visible: true, seen: true };
      }
    }
    return { visible: false, seen: !!dialog };
  })();
  """

  /// 登录成功：停掉轮询并刷新当前页，把会话 cookie 带进页面渲染。
  private func finishLoginSuccess() {
    guard !loginSucceeded else { return }
    loginSucceeded = true
    loginWatchGeneration += 1
    hintButton.isHidden = true
    setStatus("登录成功，正在刷新页面…")
    webView.reload()
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
    // 先查会话 cookie：登录成功后站点写的是 httpOnly cookie，DOM 浮层
    // 不一定关闭，只看页面会一直等下去。
    ShortVideoCookies.hasSession(for: cookieDomainNeedle) { [weak self] loggedIn in
      guard let self, generation == self.loginWatchGeneration else { return }
      // 只有这次登录流程真的开始过（看到浮层 / 已跳登录页 / 走过兜底），
      // cookie 才算「这次登录成功」；否则用户本来就有会话时点登录会白刷一次。
      let current = (self.webView.url?.absoluteString ?? "").lowercased()
      let onLoginPage = current.contains("login") || current.contains("sso")
      let started = self.loginDialogSeen || onLoginPage ||
        self.loginFallbackLoaded
      if loggedIn && started {
        self.finishLoginSuccess()
        return
      }
      self.probeLoginState(generation: generation, attempt: attempt)
    }
  }

  private func probeLoginState(generation: Int, attempt: Int) {
    guard generation == loginWatchGeneration, attempt < 60 else { return }
    let probe = """
    (function () {
      var dialog = document.querySelector(
        '[class*=login-container], [class*=loginModal], [class*=login-modal], '
        + '[id*=login-modal], [id*=login-panel], [class*=LoginModal], '
        + '[data-e2e=login-modal], [class*=TUXModal]'
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
        self.finishLoginSuccess()
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        self.probeLoginState(generation: generation, attempt: attempt + 1)
      }
    }
  }

  /// 在当前页面里找官方登录入口并点一下。
  ///
  /// 顺序：抖音头部的「登录」按钮 → 侧栏「我的」→ TikTok 的 log in 链接。
  /// 返回 true 表示点到了至少一个候选元素。
  static let loginTriggerScript: String = """
  (function () {
    var direct = document.querySelector(
      '[data-e2e=login-button], [data-e2e=nav-login], a[href*="/login"]'
    );
    if (direct) {
      var dr = direct.getBoundingClientRect();
      if (dr.width > 0 && dr.height > 0) { direct.click(); return true; }
    }
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

  /// 进页面先看会话 cookie：没有就明确告诉用户「未登录，点右上角登录」。
  private func reportLoginState() {
    loginStateProbeGeneration += 1
    let generation = loginStateProbeGeneration
    ShortVideoCookies.hasSession(for: cookieDomainNeedle) { [weak self] loggedIn in
      guard let self, generation == self.loginStateProbeGeneration,
            !self.collecting else { return }
      if loggedIn {
        self.setStatus("已登录：点右上角「开始抓取」")
        return
      }
      let current = (self.webView.url?.absoluteString ?? "").lowercased()
      if current.contains("login") || current.contains("sso") {
        self.setStatus("请在登录页完成登录，成功后自动刷新")
        return
      }
      self.setStatus("未登录，点右上角登录")
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
      let current = (webView.url?.absoluteString ?? "").lowercased()
      let onLoginPage = current.contains("login") || current.contains("sso")
      if loginFallbackLoaded && !loginFallbackClicked && !loginSucceeded &&
          !onLoginPage {
        // 兜底地址刚加载完：首页本身不会自动弹浮层，再点一次官方登录入口。
        loginFallbackClicked = true
        setStatus("正在打开登录界面…")
        let generation = loginAttemptGeneration
        webView.evaluateJavaScript(ShortVideoWebViewController.loginTriggerScript) {
          [weak self] _, _ in
          guard let self, generation == self.loginAttemptGeneration,
                !self.loginSucceeded else { return }
          self.scheduleLoginConfirm(generation: generation)
        }
      } else {
        setStatus("页面已加载，正在确认登录状态…")
        reportLoginState()
      }
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
  /// 抖音 / TikTok 登录后都会写这几个 httpOnly 会话 cookie。
  static let sessionNames: Set<String> = [
    "sessionid",
    "sessionid_ss",
    "sid_tt",
  ]

  /// 判断某个站点是否已有登录态。cookie 域里没会话 cookie 就按未登录处理。
  static func hasSession(for needle: String, completion: @escaping (Bool) -> Void) {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let found = cookies.contains { cookie in
        if !needle.isEmpty, !cookie.domain.contains(needle) { return false }
        guard sessionNames.contains(cookie.name) else { return false }
        return !cookie.value.isEmpty
      }
      DispatchQueue.main.async { completion(found) }
    }
  }

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

/// 用离屏 WKWebView 打开视频页，让页面自己把 aweme detail 请求发出来，
/// 再从响应体里取 `play_addr.url_list`。
///
/// 抖音原来的三条路现在都不能用了：`iteminfo` 接口返回空、
/// `iesdouyin/share/video/<id>` 的 `_ROUTER_DATA` 里 `video_layout` 是 null、
/// `www.douyin.com/video/<id>` 的服务端 HTML 也不含 `play_addr`（播放地址是
/// 前端 JS 异步取的）。所以只能让页面真的跑起来：`atDocumentStart` 包住
/// fetch / XMLHttpRequest，凡是响应体里带 `play_addr` 就回传；同时每 900ms
/// 读一次 `video.src` 和 `__UNIVERSAL_DATA_FOR_REHYDRATION__` / `__pace_f`
/// 做双保险。
///
/// TikTok 的 embed 页仍是服务端直出的，继续走原来的轻量 HTTP 预取。
final class ShortVideoPlayResolver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  private static let handlerName = "shortvideo_resolve"
  private static let mobileUA =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
    + "Version/15.0 Mobile/15E148 Safari/604.1"

  private let videoId: String
  private let platform: String
  private let userAgent: String
  /// url 为空时 reason 会区分 network / login / notfound，Dart 侧据此给不同提示。
  private let completion: (String?, String) -> Void
  private var webView: WKWebView?
  private var timer: Timer?
  private var ticks = 0
  private var candidate = 0
  private var finished = false
  private var networkError = false
  private var pageLoaded = false
  private var loginDetected = false
  /// TikTok 页解析失败后的重试次数（最多 2 次）。
  private var retries = 0
  /// `play_addr.uri` 拼出来的官方播放接口（302 到 mp4），直链找不到时兜底。
  private var uriFallback: String?
  private var uriFoundAt = 0

  init(
    videoId: String,
    platform: String,
    userAgent: String,
    completion: @escaping (String?, String) -> Void
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
      return [
        "https://www.douyin.com/video/\(videoId)",
        "https://www.iesdouyin.com/share/video/\(videoId)/",
        "https://m.douyin.com/share/video/\(videoId)",
      ]
    }
    return [
      "https://www.tiktok.com/embed/v2/\(videoId)",
      "https://www.tiktok.com/@i/video/\(videoId)",
      "https://m.tiktok.com/v/\(videoId).html",
    ]
  }

  private func effectiveUserAgent() -> String {
    if platform == "douyin" {
      if userAgent.contains("Mobile") || userAgent.contains("Android") {
        return userAgent
      }
      return ShortVideoPlayResolver.mobileUA
    }
    if userAgent.isEmpty {
      return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/17.4 Safari/605.1.15"
    }
    return userAgent
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
    // 必须强引用 self：prefetch 阶段还没有 webView 持有 resolver，
    // 弱引用会让对象在请求返回前就释放掉。
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
    config.defaultWebpagePreferences.preferredContentMode =
      platform == "douyin" ? .mobile : .desktop
    let controller = WKUserContentController()
    controller.add(self, name: ShortVideoPlayResolver.handlerName)
    if platform == "douyin" {
      controller.addUserScript(
        WKUserScript(
          source: ShortVideoPlayResolver.hookScript,
          injectionTime: .atDocumentStart,
          forMainFrameOnly: false
        )
      )
    }
    config.userContentController = controller
    let web = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 390, height: 844),
      configuration: config
    )
    web.customUserAgent = effectiveUserAgent()
    web.navigationDelegate = self
    webView = web
    candidate = 0
    retries = 0
    load(candidate: 0)
    let ticker = Timer(timeInterval: 0.9, repeats: true) { [weak self] _ in
      self?.poll()
    }
    RunLoop.main.add(ticker, forMode: .common)
    timer = ticker
  }

  private func load(candidate index: Int) {
    guard !finished, let web = webView else { return }
    let list = pages()
    guard index >= 0, index < list.count, let url = URL(string: list[index]) else {
      return
    }
    var request = URLRequest(url: url)
    request.setValue(effectiveUserAgent(), forHTTPHeaderField: "User-Agent")
    web.load(request)
  }

  private func poll() {
    guard !finished, let web = webView else { return }
    ticks += 1
    // 约 18 秒还没捞到就放弃，别把播放卡住。
    if ticks > 20 {
      finish(uriFallback, reason: failureReason())
      return
    }
    // 第 7 / 13 个 tick 依次换下一个候选页：
    // 抖音 www → iesdouyin/share → m.douyin/share；
    // TikTok embed → 主页 → 移动版。
    if ticks == 7 || ticks == 13 {
      let list = pages()
      let next = candidate + 1
      if next < list.count {
        candidate = next
        retries = 0
        load(candidate: candidate)
        return
      }
    }
    let js = """
    (function () {
      var out = [];
      try {
        var v = document.querySelector('video');
        if (v) {
          var src = v.currentSrc || v.src || '';
          if (src) { out.push(src); }
        }
      } catch (e) {}
      var ids = ['__UNIVERSAL_DATA_FOR_REHYDRATION__', '__pace_f', '_ROUTER_DATA'];
      for (var i = 0; i < ids.length; i++) {
        try {
          var el = document.getElementById(ids[i]);
          if (el && el.textContent && el.textContent.length > 100) {
            out.push(el.textContent);
          }
        } catch (e) {}
      }
      try {
        if (window.__UNIVERSAL_DATA_FOR_REHYDRATION__) {
          out.push(JSON.stringify(window.__UNIVERSAL_DATA_FOR_REHYDRATION__));
        }
      } catch (e) {}
      try {
        if (window.__pace_f) { out.push(String(window.__pace_f)); }
      } catch (e) {}
      try {
        var html = document.documentElement ? document.documentElement.innerHTML : '';
        if (html) { out.push(html.substring(0, 600000)); }
      } catch (e) {}
      return out.join('\\n');
    })()
    """
    web.evaluateJavaScript(js) { [self] value, _ in
      guard !self.finished else { return }
      guard let text = value as? String, text.count > 80 else { return }
      self.consume(text)
    }
  }

  private func consume(_ text: String) {
    if let url = ShortVideoPlayResolver.pick(text) {
      finish(url)
      return
    }
    if uriFallback == nil, let uri = ShortVideoPlayResolver.pickPlayURI(text) {
      uriFallback = "https://www.iesdouyin.com/aweme/v1/play/"
        + "?video_id=\(uri)&ratio=720p&line=0"
      uriFoundAt = ticks
    }
    let lower = text.lowercased()
    if lower.contains("captcha") || lower.contains("verify-center")
      || lower.contains("passport") {
      loginDetected = true
    }
  }

  private func failureReason() -> String {
    if loginDetected { return "login" }
    if !pageLoaded { return networkError ? "network" : "notfound" }
    return "notfound"
  }

  private func finish(_ url: String?, reason: String = "") {
    if finished { return }
    finished = true
    timer?.invalidate()
    timer = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.configuration.userContentController
      .removeScriptMessageHandler(forName: ShortVideoPlayResolver.handlerName)
    webView = nil
    let result = url ?? ""
    let detail = result.isEmpty ? reason : ""
    let done = completion
    DispatchQueue.main.async {
      done(result, detail)
    }
  }

  // MARK: - WKNavigationDelegate

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !finished else { return }
    pageLoaded = true
    // 登录墙通常会把地址跳到 passport / login，标题也会变。
    webView.evaluateJavaScript(
      "(function () { return (location.href || '') + '\\n' "
        + "+ (document.title || ''); })()"
    ) { [weak self] value, _ in
      guard let self = self, !self.finished else { return }
      guard let text = value as? String else { return }
      let lower = text.lowercased()
      if lower.contains("login") || lower.contains("passport")
        || lower.contains("signin") || text.contains("登录") {
        self.loginDetected = true
      }
    }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    handleNavigationFailure()
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    handleNavigationFailure()
  }

  private func handleNavigationFailure() {
    guard !finished else { return }
    networkError = true
    // TikTok 每个候选页重试 2 次再换下一个。
    if platform == "tiktok", retries < 2, ticks < 12 {
      retries += 1
      load(candidate: candidate)
      return
    }
    // 抖音某个候选页打不开时直接往后走，别把 18 秒耗在同一个域名上。
    if platform == "douyin", candidate + 1 < pages().count, ticks < 13 {
      candidate += 1
      retries = 0
      load(candidate: candidate)
    }
  }

  // MARK: - WKScriptMessageHandler

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard !finished, message.name == ShortVideoPlayResolver.handlerName else {
      return
    }
    if let body = message.body as? [String: Any],
       let text = body["body"] as? String {
      consume(text)
    } else if let text = message.body as? String {
      consume(text)
    }
  }

  /// 页面里注入的钩子：包住 fetch / XMLHttpRequest，把带播放地址的响应体回传。
  private static let hookScript = #"""
  (function () {
    if (window.__piliShortVideoResolver) { return; }
    window.__piliShortVideoResolver = true;
    var HANDLER = 'shortvideo_resolve';
    function interesting(text) {
      if (!text || text.length < 80) { return false; }
      return text.indexOf('play_addr') >= 0 || text.indexOf('url_list') >= 0;
    }
    function post(url, text) {
      try {
        if (!interesting(text)) { return; }
        window.webkit.messageHandlers[HANDLER].postMessage({
          url: String(url || ''),
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
              response.clone().text().then(function (text) {
                post(url, text);
              }).catch(function () {});
            } catch (e) {}
          }).catch(function () {});
        } catch (e) {}
        return promise;
      };
    }
    var open = XMLHttpRequest.prototype.open;
    var send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__piliURL = url;
      return open.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      try {
        xhr.addEventListener('load', function () {
          try {
            var type = xhr.responseType;
            var text = (type === '' || type === 'text') ? xhr.responseText : '';
            if (!text && typeof xhr.response === 'string') {
              text = xhr.response;
            }
            post(xhr.__piliURL, text);
          } catch (e) {}
        });
      } catch (e) {}
      return send.apply(this, arguments);
    };
  })();
  """#

  /// 在页面 JSON 里挑一条能直接下的地址：优先 play_addr.url_list。
  static func pick(_ text: String) -> String? {
    if let url = pickPlayAddr(text) { return url }
    return pickAnyCDN(text)
  }

  private static func pickPlayAddr(_ text: String) -> String? {
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let key = text.range(
            of: "\"play_addr\"",
            range: searchStart..<text.endIndex
          ) {
      let tail = String(text[key.lowerBound...].prefix(4000))
      if let url = urlList(in: tail) { return url }
      searchStart = key.upperBound
    }
    return nil
  }

  private static func urlList(in body: String) -> String? {
    guard let key = body.range(of: "\"url_list\"") else { return nil }
    guard let open = body.range(
      of: "[",
      range: key.upperBound..<body.endIndex
    ) else { return nil }
    guard let close = body.range(
      of: "]",
      range: open.upperBound..<body.endIndex
    ) else { return nil }
    let array = body[open.upperBound..<close.lowerBound]
    var fallback: String?
    for raw in array.split(separator: "\"") {
      var token = unescape(String(raw))
      guard token.hasPrefix("http"), isPlayable(token) else { continue }
      if token.contains("playwm") {
        token = token.replacingOccurrences(of: "playwm", with: "play")
      }
      if token.contains("mime_type=video_mp4") { return token }
      if fallback == nil { fallback = token }
    }
    return fallback
  }

  private static func pickAnyCDN(_ text: String) -> String? {
    var fallback: String?
    for raw in text.split(separator: "\"") {
      guard raw.contains("http") else { continue }
      var token = unescape(String(raw))
      guard token.hasPrefix("http"), isPlayable(token) else { continue }
      if token.contains("playwm") {
        token = token.replacingOccurrences(of: "playwm", with: "play")
      }
      if token.contains("mime_type=video_mp4") { return token }
      if fallback == nil { fallback = token }
    }
    return fallback
  }

  private static func isPlayable(_ token: String) -> Bool {
    return token.contains("/video/tos/")
      || token.contains("aweme/v1/play/")
      || token.contains("douyinvod")
      || token.contains("mime_type=video_mp4")
  }

  /// `play_addr.uri` 是官方播放接口的参数，直链都拿不到时用它兜底。
  static func pickPlayURI(_ text: String) -> String? {
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let key = text.range(
            of: "\"play_addr\"",
            range: searchStart..<text.endIndex
          ) {
      let tail = String(text[key.lowerBound...].prefix(4000))
      if let uri = uriValue(in: tail) { return uri }
      searchStart = key.upperBound
    }
    return nil
  }

  private static func uriValue(in body: String) -> String? {
    guard let key = body.range(of: "\"uri\"") else { return nil }
    guard let colon = body.range(
      of: ":",
      range: key.upperBound..<body.endIndex
    ) else { return nil }
    guard let open = body.range(
      of: "\"",
      range: colon.upperBound..<body.endIndex
    ) else { return nil }
    guard let close = body.range(
      of: "\"",
      range: open.upperBound..<body.endIndex
    ) else { return nil }
    let uri = unescape(String(body[open.upperBound..<close.lowerBound]))
    guard !uri.isEmpty, !uri.contains(" ") else { return nil }
    return uri
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

/// 从视频页里取评论。
///
/// 和 `ShortVideoPlayResolver` 一样开离屏 WKWebView，但只截评论接口：
/// hook 判断响应体里有没有 `"comments"` / `"comment_list"`，有就回传。
/// 页面自身的评论懒加载依赖点击评论入口，所以轮询里会先点一次评论图标，
/// 再从 DOM 里兜底读已渲染的评论节点。12 秒还没结果就返回空。
final class ShortVideoCommentResolver: NSObject, WKScriptMessageHandler,
  WKNavigationDelegate {

  private static let handlerName = "shortvideo_comments"

  private let videoId: String
  private let platform: String
  private let userAgent: String
  private let limit: Int
  /// 评论列表；为空时 reason 区分 empty / login / network / notfound。
  private let completion: ([[String: Any]], String) -> Void

  private var webView: WKWebView?
  private var timer: Timer?
  private var ticks = 0
  private var candidate = 0
  private var finished = false
  private var networkError = false
  private var pageLoaded = false
  private var loginDetected = false
  private var collected: [[String: Any]] = []
  private var seen: Set<String> = []

  init(
    videoId: String,
    platform: String,
    userAgent: String,
    limit: Int,
    completion: @escaping ([[String: Any]], String) -> Void
  ) {
    self.videoId = videoId
    self.platform = platform
    self.userAgent = userAgent
    self.limit = limit
    self.completion = completion
    super.init()
  }

  func start() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.defaultWebpagePreferences.preferredContentMode = .desktop
    let controller = WKUserContentController()
    controller.add(self, name: ShortVideoCommentResolver.handlerName)
    controller.addUserScript(
      WKUserScript(
        source: ShortVideoCommentResolver.hookScript,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
      )
    )
    config.userContentController = controller
    let web = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 390, height: 844),
      configuration: config
    )
    web.customUserAgent = effectiveUserAgent()
    web.navigationDelegate = self
    webView = web
    load(candidate: 0)
    let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.poll()
    }
    RunLoop.main.add(ticker, forMode: .common)
    timer = ticker
  }

  private func pages() -> [String] {
    if platform == "douyin" {
      return [
        "https://www.douyin.com/video/\(videoId)",
        "https://www.iesdouyin.com/share/video/\(videoId)/",
        "https://m.douyin.com/share/video/\(videoId)",
      ]
    }
    return [
      "https://www.tiktok.com/@i/video/\(videoId)",
      "https://m.tiktok.com/v/\(videoId).html",
    ]
  }

  private func effectiveUserAgent() -> String {
    if userAgent.contains("Mobile") || userAgent.contains("Android") {
      return userAgent
    }
    if !userAgent.isEmpty {
      return userAgent
    }
    return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
      + "Version/17.4 Safari/605.1.15"
  }

  private func load(candidate index: Int) {
    guard !finished, let web = webView else { return }
    let list = pages()
    guard index >= 0, index < list.count, let url = URL(string: list[index])
    else { return }
    pageLoaded = false
    networkError = false
    var request = URLRequest(url: url)
    request.setValue(effectiveUserAgent(), forHTTPHeaderField: "User-Agent")
    let referer = platform == "douyin"
      ? "https://www.douyin.com/"
      : "https://www.tiktok.com/"
    request.setValue(referer, forHTTPHeaderField: "Referer")
    request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    web.load(request)
  }

  private func poll() {
    guard !finished, let web = webView else { return }
    ticks += 1
    if ticks >= 12 {
      finish(reason: collected.isEmpty ? failureReason() : "")
      return
    }
    if collected.isEmpty, ticks == 5 || ticks == 9 {
      let next = candidate + 1
      if next < pages().count {
        candidate = next
        load(candidate: candidate)
        return
      }
    }
    // 接口 hook 到第 8 拍仍未收到任何评论：允许 DOM 兜底（只此一次置位，
    // 之后 pollScript 才会读 DOM，且不参与 limit 早退，见 consume）。
    if collected.isEmpty, ticks == 8 {
      web.evaluateJavaScript("window.__piliCommentDomFallback = true;")
    }
    web.evaluateJavaScript(ShortVideoCommentResolver.pollScript) {
      [weak self] value, _ in
      guard let self = self, !self.finished else { return }
      guard let text = value as? String, !text.isEmpty else { return }
      self.consume(text)
    }
  }

  private func consume(_ text: String) {
    // pollScript 的 DOM 兜底结果带 `dom: true` 标记：只允许在接口一条都没
    // 收到时采用，且绝不因凑够 limit 提前结束（避免把 DOM 的兜底行混进
    // 接口结果、或提前关掉 12 秒窗口）。
    let isDom = text.contains("\"dom\":true")
    if isDom, !collected.isEmpty { return }
    let parsed = ShortVideoCommentResolver.parse(text: text, limit: limit)
    if parsed.isEmpty {
      let lower = text.lowercased()
      if lower.contains("captcha") || lower.contains("verify-center")
        || lower.contains("passport") {
        loginDetected = true
      }
      return
    }
    for item in parsed {
      guard collected.count < limit else { break }
      let author = item["author"] as? String ?? ""
      let body = item["text"] as? String ?? ""
      let key = "\(author)|\(body)"
      if seen.insert(key).inserted {
        collected.append(item)
      }
    }
    // DOM 兜底不参与「凑够即结束」，让 12 秒窗口跑满再收尾。
    if !isDom, collected.count >= limit {
      finish(reason: "")
    }
  }

  private func failureReason() -> String {
    if loginDetected { return "login" }
    if !pageLoaded { return networkError ? "network" : "notfound" }
    return "empty"
  }

  private func finish(reason: String) {
    if finished { return }
    finished = true
    timer?.invalidate()
    timer = nil
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    webView?.configuration.userContentController
      .removeScriptMessageHandler(forName: ShortVideoCommentResolver.handlerName)
    webView = nil
    let comments = collected
    let detail = comments.isEmpty ? (reason.isEmpty ? "empty" : reason) : ""
    let done = completion
    DispatchQueue.main.async {
      done(comments, detail)
    }
  }

  // MARK: - WKNavigationDelegate

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !finished else { return }
    pageLoaded = true
    webView.evaluateJavaScript(
      "(function () { return (location.href || '') + '\\n' "
        + "+ (document.title || ''); })()"
    ) { [weak self] value, _ in
      guard let self = self, !self.finished else { return }
      guard let text = value as? String else { return }
      let lower = text.lowercased()
      if lower.contains("login") || lower.contains("passport")
        || lower.contains("signin") {
        self.loginDetected = true
      }
    }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    handleNavigationFailure()
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    handleNavigationFailure()
  }

  private func handleNavigationFailure() {
    guard !finished else { return }
    networkError = true
    if candidate + 1 < pages().count, ticks < 9 {
      candidate += 1
      load(candidate: candidate)
    }
  }

  // MARK: - WKScriptMessageHandler

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard !finished, message.name == ShortVideoCommentResolver.handlerName else {
      return
    }
    if let body = message.body as? [String: Any],
       let text = body["body"] as? String {
      consume(text)
    } else if let text = message.body as? String {
      consume(text)
    }
  }

  // MARK: - 页面脚本

  /// 只回传评论接口的响应体，避免把整页收藏 JSON 都塞进通道。
  private static let hookScript = #"""
  (function () {
    if (window.__piliCommentHook) { return; }
    window.__piliCommentHook = true;
    var HANDLER = 'shortvideo_comments';
    function interesting(text) {
      if (!text || text.length < 40) { return false; }
      return text.indexOf('"comments"') >= 0
        || text.indexOf('"comment_list"') >= 0
        || text.indexOf('"commentList"') >= 0;
    }
    function post(url, text) {
      try {
        if (!interesting(text)) { return; }
        window.webkit.messageHandlers[HANDLER].postMessage({
          url: String(url || ''),
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
              response.clone().text().then(function (text) {
                post(url, text);
              }).catch(function () {});
            } catch (e) {}
          }).catch(function () {});
        } catch (e) {}
        return promise;
      };
    }
    var open = XMLHttpRequest.prototype.open;
    var send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__piliCommentURL = url;
      return open.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      try {
        xhr.addEventListener('load', function () {
          try {
            var type = xhr.responseType;
            var text = '';
            if (type === '' || type === 'text') {
              text = xhr.responseText || '';
            } else if (type === 'json' && xhr.response) {
              text = JSON.stringify(xhr.response);
            }
            if (!text && typeof xhr.response === 'string') {
              text = xhr.response;
            }
            post(xhr.__piliCommentURL, text);
          } catch (e) {}
        });
      } catch (e) {}
      return send.apply(this, arguments);
    };
  })();
  """#

  /// 点开评论入口，然后优先读接口已抓到的内容；接口没触发时读 DOM 兜底。
  private static let pollScript = #"""
  (function () {
    try {
      if (!window.__piliCommentClicked) {
        var trigger = document.querySelector(
          '[data-e2e="comment-icon"], [data-e2e="feed-comment-icon"], '
          + '[data-e2e="comment-count"]'
        );
        if (trigger) {
          window.__piliCommentClicked = true;
          trigger.click();
        }
      }
    } catch (e) {}
    try {
      var height = document.body ? document.body.scrollHeight : 0;
      if (height > window.innerHeight) {
        window.scrollTo(0, Math.min(height, window.scrollY + 800));
      }
    } catch (e) {}
    // DOM 兜底只在接口 hook 一条都没收到时启用（Swift 在 ticks>=8 且
    // collected 为空时置 __piliCommentDomFallback）。否则会和接口结果
    // 混在一起，产生「匿名用户」重复行并提前触发 limit。
    try {
      if (window.__piliCommentDomFallback) {
        var nodes = document.querySelectorAll(
          '[data-e2e="comment-item"], [data-e2e="comment-level-1"], '
          + '[class*="comment-item"]'
        );
        if (nodes.length) {
          var out = [];
          for (var i = 0; i < nodes.length && out.length < 60; i++) {
            var node = nodes[i];
            var nick = '';
            var likes = 0;
            var body = '';
            try {
              var n = node.querySelector(
                '[data-e2e*="username"], [class*="username"], '
                + '[class*="nickname"], [class*="user-name"]'
              );
              if (n) { nick = (n.innerText || '').trim(); }
              var l = node.querySelector(
                '[data-e2e*="like"],[class*="like-count"],[class*="likeCount"]'
              );
              if (l) {
                var m = (l.innerText || '').match(/\d+/);
                if (m) { likes = parseInt(m[0], 10) || 0; }
              }
              var c = node.querySelector(
                '[data-e2e="comment-level-1"], [class*="comment-content"], '
                + '[class*="content"]'
              );
              body = ((c ? c.innerText : node.innerText) || '').trim();
              if (nick && body.indexOf(nick) === 0) {
                body = body.substring(nick.length).trim();
              }
            } catch (e) {
              body = (node.innerText || '').trim();
            }
            if (body) {
              out.push({ author: nick, text: body, likes: likes, time: 0 });
            }
          }
          if (out.length) {
            return JSON.stringify({ comments: out, dom: true });
          }
        }
      }
    } catch (e) {}
    try {
      if (!window.__piliCommentRehydrationChecked) {
        var el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
        if (el && el.textContent) {
          window.__piliCommentRehydrationChecked = true;
          var data = el.textContent;
          if (data.length > 100 && data.length < 8000000
            && (data.indexOf('"comments"') >= 0
              || data.indexOf('"comment_list"') >= 0
              || data.indexOf('"commentList"') >= 0)) {
            return data;
          }
        }
      }
    } catch (e) {}
    return '';
  })()
  """#

  // MARK: - 解析

  private static func parse(text: String, limit: Int) -> [[String: Any]] {
    guard text.count > 40,
          let data = text.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data)
    else { return [] }
    var out: [[String: Any]] = []
    var seen: Set<String> = []
    walk(root, depth: 0, limit: limit, out: &out, seen: &seen)
    return out
  }

  private static func walk(
    _ node: Any,
    depth: Int,
    limit: Int,
    out: inout [[String: Any]],
    seen: inout Set<String>
  ) {
    if depth > 12 || out.count >= limit { return }
    if let dict = node as? [String: Any] {
      if let list = dict["comments"] as? [Any]
        ?? dict["comment_list"] as? [Any]
        ?? dict["commentList"] as? [Any] {
        for raw in list {
          guard out.count < limit else { return }
          guard let item = raw as? [String: Any],
                let comment = makeComment(item) else { continue }
          let author = comment["author"] as? String ?? ""
          let body = comment["text"] as? String ?? ""
          if seen.insert("\(author)|\(body)").inserted {
            out.append(comment)
          }
        }
      }
      for (key, value) in dict {
        if key == "comments" || key == "comment_list" || key == "commentList" {
          continue
        }
        if value is [String: Any] || value is [Any] {
          walk(value, depth: depth + 1, limit: limit, out: &out, seen: &seen)
        }
      }
    } else if let list = node as? [Any] {
      for value in list where value is [String: Any] || value is [Any] {
        walk(value, depth: depth + 1, limit: limit, out: &out, seen: &seen)
      }
    }
  }

  private static func makeComment(_ item: [String: Any]) -> [String: Any]? {
    guard let text = stringValue(item["text"]) ?? stringValue(item["content"]),
          !text.isEmpty, text.count <= 2000
    else { return nil }
    let user = item["user"] as? [String: Any]
    let author = stringValue(user?["nickname"])
      ?? stringValue(user?["unique_id"])
      ?? stringValue(user?["name"])
      ?? stringValue(item["author"])
      ?? ""
    let likes = intValue(item["digg_count"])
      ?? intValue(item["like_count"])
      ?? intValue(item["likes"])
      ?? 0
    let time = intValue(item["create_time"])
      ?? intValue(item["createTime"])
      ?? 0
    return [
      "author": author,
      "text": text,
      "likes": likes,
      "time": time,
    ]
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }
}
