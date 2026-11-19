import Foundation
import UIKit
import Flutter

/// 视图层级诊断。
///
/// 用途只有一个：在用户报「整页点不动」时，把 App 窗口里真实的 view 层级
/// 写成文本，而不是让开发者在 Dart 侧猜是哪一层挡住了事件。
///
/// 报错「按钮全部点不动、返回不了、但画中画正常」时，两种情况必须分开：
///   1. Flutter 的渲染视图被某个不透明的原生视图盖住了 —— 这里能直接看到
///   2. Flutter 自己在收事件但没处理 —— 这里能看到层级是干净的
///
/// 输出写到 Documents/ui_hierarchy.txt，Filza 或「文件」App 都能打开。
final class PiliViewDiag: NSObject, FlutterPlugin {
  static let channelName = "piliplus/view_diag"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(PiliViewDiag(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "dump":
      let text = Self.describeWindows()
      let path = Self.write(text)
      result(["path": path ?? "", "text": text])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func write(_ text: String) -> String? {
    guard
      let dir = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
      ).first
    else { return nil }
    let url = dir.appendingPathComponent("ui_hierarchy.txt")
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      return url.path
    } catch {
      return nil
    }
  }

  /// 把每个窗口、每个子视图的层级、frame、是否接收触摸都写出来。
  ///
  /// 关键信息是 `hit`：false 说明这一层不接收触摸，若它把 Flutter 视图整个
  /// 盖住，用户就会看到「整页点不动」。
  static func describeWindows() -> String {
    var lines: [String] = []
    lines.append("=== windows (\(Date())) ===")

    let scenes = UIApplication.shared.connectedScenes
    for scene in scenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      lines.append("scene state=\(scene.activationState.rawValue)"
                   + " windows=\(windowScene.windows.count)")
      for (index, window) in windowScene.windows.enumerated() {
        lines.append("window[\(index)] key=\(window.isKeyWindow)"
                     + " hidden=\(window.isHidden)"
                     + " alpha=\(window.alpha)"
                     + " level=\(window.windowLevel.rawValue)"
                     + " frame=\(describe(window.frame))")
        for (depth, path) in walk(window).enumerated() {
          lines.append("  [\(depth)] \(path)")
        }
      }
    }

    if lines.count <= 1 {
      lines.append("no window scene found")
    }
    return lines.joined(separator: "\n")
  }

  /// 深度优先遍历，带缩进。
  private static func walk(_ root: UIView) -> [String] {
    var out: [String] = []
    func visit(_ view: UIView, depth: Int) {
      let indent = String(repeating: "  ", count: depth)
      out.append(
        "\(indent)\(type(of: view))"
        + " frame=\(describe(view.frame))"
        + " hidden=\(view.isHidden)"
        + " alpha=\(String(format: "%.2f", view.alpha))"
        + " hit=\(view.isUserInteractionEnabled)"
        + " clips=\(view.clipsToBounds)"
      )
      for child in view.subviews {
        visit(child, depth: depth + 1)
      }
    }
    visit(root, depth: 0)
    return out
  }

  private static func describe(_ rect: CGRect) -> String {
    String(
      format: "%.0f,%.0f %.0fx%.0f",
      rect.origin.x, rect.origin.y, rect.width, rect.height
    )
  }
}
