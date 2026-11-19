import Foundation
import UIKit
import QuartzCore
import Flutter

/// PiliPlus 根因扫描器（原生侧）。
///
/// 目的：用户报「播放页整页点不动、返回不了、起播很慢」，而这些症状在
/// Dart 代码里看起来每次都「应该有修复」。为了不再靠读代码猜，这里把
/// 一切能客观测量的东西一次性全部采集出来，写进一个 JSON：
///
///   * 视图层级：每个 UIView 的 frame / hidden / alpha / 是否接收触摸
///   * 命中测试：指定坐标上真实命中的是哪条 view 链（能直接看出谁盖住了谁）
///   * 主线程健康：主线程是否被长任务卡住（卡住 = UI 必然「死」）
///   * 渲染帧：CADisplayLink 实测帧间隔与掉帧
///   * 内存与进程：可用内存（6S 只有 2GB，播放器一吃紧就卡）
///
/// 全部只读，不改任何页面逻辑。任何一步失败都单独记错误，不影响其它项。
final class PiliRootScan: NSObject, FlutterPlugin {
  static let channelName = "piliplus/rootscan"

  /// 采集窗口。太短测不出卡顿，太长用户等不住。
  private var displayLink: CADisplayLink?
  private var frameStamps: [CFTimeInterval] = []
  private var collectUntil: CFTimeInterval = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(PiliRootScan(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "scan":
      let args = call.arguments as? [String: Any] ?? [:]
      let seconds = (args["seconds"] as? NSNumber)?.doubleValue ?? 3.0
      let points = args["points"] as? [[String: Any]] ?? []
      startScan(seconds: seconds, points: points, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 采一段帧，然后一次性交回结果。
  private func startScan(
    seconds: Double,
    points: [[String: Any]],
    result: @escaping FlutterResult
  ) {
    collectUntil = CACurrentMediaTime() + seconds
    frameStamps = []

    let link = CADisplayLink(target: self, selector: #selector(onFrame))
    link.add(to: .main, forMode: .common)
    displayLink = link

    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.2) { [weak self] in
      guard let self else { return }
      self.displayLink?.invalidate()
      self.displayLink = nil
      result(self.buildReport(points: points))
    }
  }

  @objc private func onFrame(_ link: CADisplayLink) {
    frameStamps.append(CACurrentMediaTime())
  }

  // MARK: - 报告

  private func buildReport(points: [[String: Any]]) -> [String: Any] {
    var report: [String: Any] = [:]
    report["scannedAt"] = ISO8601DateFormatter().string(from: Date())
    report["device"] = deviceInfo()
    report["windows"] = windowReport()
    report["hitTests"] = hitTests(points)
    report["frames"] = frameStats()
    report["mainThread"] = mainThreadProbe()
    return report
  }

  private func deviceInfo() -> [String: Any] {
    let process = ProcessInfo.processInfo
    return [
      "systemVersion": UIDevice.current.systemVersion,
      "model": UIDevice.current.model,
      "screenScale": UIScreen.main.scale,
      "screenSize": [
        "w": UIScreen.main.bounds.width,
        "h": UIScreen.main.bounds.height,
      ],
      "physicalMB": Double(process.physicalMemory) / 1_048_576,
      "lowPowerMode": process.isLowPowerModeEnabled,
    ]
  }

  /// 所有窗口和视图，逐层列出关键属性。
  private func windowReport() -> [[String: Any]] {
    var out: [[String: Any]] = []
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for (index, window) in windowScene.windows.enumerated() {
        var entry: [String: Any] = [
          "index": index,
          "key": window.isKeyWindow,
          "hidden": window.isHidden,
          "alpha": window.alpha,
          "level": window.windowLevel.rawValue,
          "frame": frameDict(window.frame),
          "viewCount": countViews(window),
        ]
        entry["tree"] = walk(window)
        out.append(entry)
      }
    }
    return out
  }

  private func countViews(_ root: UIView) -> Int {
    var total = 1
    for child in root.subviews {
      total += countViews(child)
    }
    return total
  }

  /// 整棵树。深度限制避免异常结构把报告撑爆。
  private func walk(_ root: UIView, depth: Int = 0) -> [[String: Any]] {
    guard depth < 24 else { return [] }
    var out: [[String: Any]] = []
    for view in root.subviews {
      var entry: [String: Any] = [
        "depth": depth,
        "type": "\(type(of: view))",
        "frame": frameDict(view.frame),
        "hidden": view.isHidden,
        "alpha": view.alpha,
        "hit": view.isUserInteractionEnabled,
        "clips": view.clipsToBounds,
      ]
      // 只对可疑层额外拍平面：盖住屏幕但透明度极低的东西最容易漏掉。
      if view.alpha <= 0.05 && !view.isHidden {
        entry["suspect"] = "near_invisible_but_present"
      }
      if view.isUserInteractionEnabled == false && view.alpha > 0.5
        && !view.isHidden && view.frame.width > 100 {
        entry["suspect"] = "large_non_interactive"
      }
      out.append(entry)
      out.append(contentsOf: walk(view, depth: depth + 1))
    }
    return out
  }

  /// 在给定坐标上做命中测试，把命中的 view 链原样列出来。
  ///
  /// 这是回答「谁盖住了 Flutter」最直接的手段：如果 (20, 60) 这个返回按钮
  /// 位置命中的第一条不是 FlutterView 也不是 Flutter 的按钮，而是别的东
  /// 西，那就找到罪魁了。
  private func hitTests(_ points: [[String: Any]]) -> [[String: Any]] {
    var out: [[String: Any]] = []
    guard
      let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
      let window = scene.windows.first(where: { $0.isKeyWindow })
        ?? scene.windows.first
    else { return out }

    for point in points {
      let x = (point["x"] as? NSNumber)?.doubleValue ?? 0
      let y = (point["y"] as? NSNumber)?.doubleValue ?? 0
      let label = point["label"] as? String ?? ""
      let location = CGPoint(x: x, y: y)
      var chain: [String] = []
      var current: UIView? = window.hitTest(location, with: nil)
      while let view = current {
        chain.append("\(type(of: view))"
                     + " frame=\(describe(view.frame))"
                     + " hit=\(view.isUserInteractionEnabled)")
        current = view.superview
      }
      out.append([
        "label": label,
        "x": x,
        "y": y,
        "chain": chain,
        "topmost": chain.first ?? "nil",
      ])
    }
    return out
  }

  /// 实测帧间隔。掉帧严重时 UI 看起来就是「卡死」。
  private func frameStats() -> [String: Any] {
    guard frameStamps.count > 1 else {
      return ["samples": frameStamps.count, "note": "too few frames"]
    }
    var gaps: [Double] = []
    for index in 1..<frameStamps.count {
      gaps.append((frameStamps[index] - frameStamps[index - 1]) * 1000)
    }
    let sorted = gaps.sorted()
    let total = gaps.reduce(0, +)
    let mean = total / Double(gaps.count)
    let p95 = sorted[Int(Double(sorted.count) * 0.95)]
    let worst = sorted.last ?? 0
    let longFrames = gaps.filter { $0 > 50 }.count
    return [
      "samples": gaps.count,
      "meanMs": mean,
      "p95Ms": p95,
      "worstMs": worst,
      "framesOver50ms": longFrames,
      "fps": mean > 0 ? 1000 / mean : 0,
      "verdict": longFrames > gaps.count / 4 ? "janky" : "ok",
    ]
  }

  /// 主线程健康：投一个空任务，看它多久才被执行。
  ///
  /// 返回的 delay 就是主线程当前被占用的程度。超过 100ms 说明有同步重活，
  /// 此时用户点任何按钮都不会有反应——这正是「整页点不动」的一种成因。
  private func mainThreadProbe() -> [String: Any] {
    let start = CACurrentMediaTime()
    let semaphore = DispatchSemaphore(value: 0)
    var delay = 0.0
    DispatchQueue.main.async {
      delay = (CACurrentMediaTime() - start) * 1000
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2)
    return [
      "dispatchDelayMs": delay,
      "blocked": delay > 100,
    ]
  }

  private func frameDict(_ rect: CGRect) -> [String: Double] {
    [
      "x": rect.origin.x,
      "y": rect.origin.y,
      "w": rect.width,
      "h": rect.height,
    ]
  }

  private func describe(_ rect: CGRect) -> String {
    String(format: "%.0f,%.0f %.0fx%.0f",
           rect.origin.x, rect.origin.y, rect.width, rect.height)
  }
}
