import Flutter
import UIKit

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PipPlugin") {
      PipPlugin.register(with: registrar)
    }
    // 抖音 / TikTok 的原生通道。不注册就没有登录网页、抓收藏、直链重解析和
    // 原生下载——Dart 侧所有相关调用都会抛 MissingPluginException，被 catch
    // 吞掉后表现为「点了没反应」「只能播过期直链、只有声音没有画面」。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ShortVideoWebView") {
      ShortVideoWebViewPlugin.register(with: registrar)
    }
    // 视图层级诊断。用户报「整页点不动」时用它把真实的 view 层级写出来，
    // 直接判断是原生视图盖住了 Flutter，还是 Flutter 自己没处理事件。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PiliViewDiag") {
      PiliViewDiag.register(with: registrar)
    }
    // 根因扫描器。一次性采集视图层级、命中测试、帧率、主线程阻塞，
    // 全部导成一个 JSON，避免再靠读代码猜「到底哪一层吃了事件」。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PiliRootScan") {
      PiliRootScan.register(with: registrar)
    }
    // 诊断导出：Dart 侧把日志打成 zip，这里弹系统分享面板；appInfo 读真实
    // bundle 版本与硬件标识，避免再出现「不知道用户装的是哪一版」。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DiagExportPlugin") {
      DiagExportPlugin.register(with: registrar)
    }
  }
}

/// 诊断导出通道（`piliplus/diag_export`）。
///
/// 只做两件事：把 Dart 打好的 zip 交给 `UIActivityViewController`，以及
/// 返回 `mainBundle` 里的真实版本号 / 系统版本 / 机型标识。
final class DiagExportPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "piliplus/diag_export",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(DiagExportPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "appInfo":
      result(Self.appInfo())
    case "shareFile":
      guard
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        FileManager.default.fileExists(atPath: path)
      else {
        result(FlutterError(code: "NO_FILE", message: "diagnostic file missing", details: nil))
        return
      }
      guard let root = Self.rootViewController() else {
        result(FlutterError(code: "NO_VC", message: "no root view controller", details: nil))
        return
      }
      let controller = UIActivityViewController(
        activityItems: [URL(fileURLWithPath: path)],
        applicationActivities: nil
      )
      if let popover = controller.popoverPresentationController {
        popover.sourceView = root.view
        popover.sourceRect = CGRect(
          x: root.view.bounds.midX,
          y: root.view.bounds.midY,
          width: 1,
          height: 1
        )
        popover.permittedArrowDirections = []
      }
      root.present(controller, animated: true, completion: nil)
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func appInfo() -> [String: String] {
    let info = Bundle.main.infoDictionary
    var systemInfo = utsname()
    _ = uname(&systemInfo)
    let model = withUnsafeBytes(of: &systemInfo.machine) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return [
      "version": info?["CFBundleShortVersionString"] as? String ?? "",
      "build": info?["CFBundleVersion"] as? String ?? "",
      "systemVersion": UIDevice.current.systemVersion,
      "model": model,
    ]
  }

  private static func rootViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    let window = windows.first { $0.isKeyWindow } ?? windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
