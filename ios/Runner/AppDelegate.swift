import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    application.applicationSupportsShakeToEdit = false // Disable shake to undo
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShortVideoWebView") {
      ShortVideoWebViewPlugin.register(with: registrar)
    }
  }
}

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

  @objc private func openLogin() {
    load(loginURL)
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
    setStatus("正在抓取…如果一直没动静，请先在网页里登录")
    installHook { [weak self] in
      guard let self else { return }
      self.webView.evaluateJavaScript(self.driverScript)
      self.startTimer()
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
      "try{clearInterval(window.__kumoneDriver);window.__kumoneDriver=null;}catch(e){}"
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
          let payload = message.body as? [String: Any],
          let body = payload["body"] as? String else { return }
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
  /// `window.open` / `target=_blank` 一律在本页打开。
  ///
  /// 抖音的「登录」、搜索结果、视频详情全是新窗口链接；不实现这个回调，
  /// 点了就什么都不发生——这正是「登录按钮点不动」的真正原因。
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url {
      let scheme = (url.scheme ?? "").lowercased()
      if scheme == "http" || scheme == "https" || scheme == "about" {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webView.load(request)
      }
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