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
  }
}
