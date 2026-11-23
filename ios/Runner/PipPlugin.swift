import AVKit
import CoreImage
import Flutter
import UIKit

/// Picture-in-Picture for the video texture rendered by media_kit (mpv).
///
/// mpv renders into `CVPixelBuffer`s owned by a `FlutterTexture` that is
/// private to media_kit_video, so the engine's texture registry is hooked to
/// map texture ids to textures and to get notified of new frames. Frames of the
/// tracked texture are copied and fed to an `AVSampleBufferDisplayLayer`, which
/// is used as the PiP content source (iOS 15+).
final class PipPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.example.piliplus/pip"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = PipPlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    TextureTracker.install(on: registrar.textures())
    // 注册即落一行 session start：只要文件存在，就说明原生插件真的被注册过。
    // 反过来，如果用户报「PiP 卡」但连这行都没有，问题根本不在帧链路，
    // 而是 App 没进到原生插件（或装错了版本）。
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? "unknown"
    PipTrace.log(
      "session start: version=\(version)(\(build)) system=\(UIDevice.current.systemVersion) "
        + "model=\(deviceModelIdentifier())"
    )
  }

  /// `UIDevice.model` 只说 "iPhone"，这里取真正的硬件标识（如 iPhone12,1）。
  private static func deviceModelIdentifier() -> String {
    var info = utsname()
    _ = uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  private let channel: FlutterMethodChannel
  private var _session: AnyObject?

  @available(iOS 15.0, *)
  private var session: PipSession? {
    get { _session as? PipSession }
    set { _session = newValue }
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    TextureTracker.onFrameAvailable = { [weak self] textureId in
      guard #available(iOS 15.0, *), let session = self?.session,
        session.textureId == textureId
      else { return }
      session.frameAvailable()
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 15.0, *) else {
      result(call.method == "isAvailable" ? false : nil)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    PipTrace.log("handle(\(call.method)) args=\(args.keys.sorted())")
    switch call.method {
    case "isAvailable":
      result(AVPictureInPictureController.isPictureInPictureSupported())
    case "enter":
      guard let textureId = (args["textureId"] as? NSNumber)?.int64Value else {
        result(FlutterError(code: "ARGS", message: "textureId is required", details: nil))
        return
      }
      let session: PipSession
      if let current = self.session, current.textureId == textureId {
        session = current
      } else {
        tearDown()
        session = PipSession(textureId: textureId) { [weak self] method, arguments in
          self?.channel.invokeMethod(method, arguments: arguments)
        }
        session.onStop = { [weak self, weak session] in
          // Keep the session alive while armed for auto-enter.
          guard let self, let session, self.session === session,
            !session.autoEnter
          else { return }
          self.tearDown()
        }
        self.session = session
      }
      session.configure(
        width: (args["width"] as? NSNumber)?.doubleValue ?? 16,
        height: (args["height"] as? NSNumber)?.doubleValue ?? 9
      )
      session.update(args)
      if args["autoEnter"] as? Bool == true {
        session.autoEnter = true
      } else {
        session.start()
      }
      result(nil)
    case "update":
      session?.update(args)
      result(nil)
    case "disableAutoEnter":
      if let session {
        session.autoEnter = false
        if !session.isActive {
          tearDown()
        }
      }
      result(nil)
    case "dispose":
      tearDown()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 15.0, *)
  private func tearDown() {
    session?.invalidate()
    session = nil
  }
}

// MARK: - Session


// MARK: - PiP trace
//
// 6S 画中画卡帧查了多轮都没定位到具体断点，因为关键状态全在内存里、取不出来。
// 这里把每一步的实际值写到 Documents/pip_trace.log：用户进一次播放页、点一次
// 画中画、回一次主屏，就能拿到完整链路，不用再猜。
// 只写不读，任何异常都吞掉，绝不影响播放。
enum PipTrace {
  private static let queue = DispatchQueue(label: "com.example.piliplus.piptrace")
  private static var fileURL: URL? = {
    guard
      let dir = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
      ).first
    else { return nil }
    return dir.appendingPathComponent("pip_trace.log")
  }()

  static func log(_ message: String) {
    let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
    queue.async {
      guard let url = fileURL, let data = line.data(using: .utf8) else { return }
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? data.write(to: url)
      }
    }
  }
}

@available(iOS 15.0, *)
private final class PipSession: NSObject {
  /// Upper bound of the longest side of the frames sent to PiP.
  private static let maxDimension = 1920.0
  /// Frame interval used while armed for auto-enter but not yet in PiP.
  private static let idleFrameInterval = 0.25

  let textureId: Int64
  var onStop: (() -> Void)?
  private(set) var isActive = false

  var autoEnter = false {
    didSet { updateAutoEnter() }
  }

  private let sendEvent: (String, Any?) -> Void
  private let sourceView: SampleBufferView
  private let displayLayer: AVSampleBufferDisplayLayer
  private let timebase: CMTimebase
  private var controller: AVPictureInPictureController!
  private var possibleObservation: NSKeyValueObservation?
  private var observers: [NSObjectProtocol] = []
  private var enteredBackground = false

  private var isPlaying = false
  private var isBuffering = false
  private var isLive = false
  private var speed = 1.0
  /// Latest playback position pushed by Dart, in milliseconds.
  private var positionMs: Int64 = 0
  private var duration = CMTime.zero
  private var pendingStart = false
  private var stopRequested = false
  private var restoring = false
  /// Whether to leave the app once PiP has started, see `start()`.
  private var backgroundOnStart = false
  private var frameInFlight = false
  private var lastFrameTime: CFTimeInterval = 0
  private var frameInFlightSince: CFTimeInterval = 0
  private var frameGeneration = 0
  private var textureCallbackCount = 0
  private var frameInFlightDropCount = 0
  private var throttleDropCount = 0
  private var enqueuedFrameCount = 0
  private var shownFrameCount = 0
  private var droppedOldFrameCount = 0
  private var directFrameCount = 0
  private var renderFrameCount = 0
  /// Main thread only: a newer frame arrived while `frameInFlight` was busy.
  /// The buffer cannot be retained here (mpv recycles it), so the newest
  /// texture frame is pulled again once the in-flight frame is done.
  private var pendingFrameRequested = false
  private var lastTextureCallbackTime: CFTimeInterval = 0
  private var callbackWindowStart: CFTimeInterval = 0
  private var callbackWindowCount = 0
  /// 画中画 seek 的代数。异步补帧任务只认最新一次 seek，避免连续点
  /// 快进/快退时旧任务在新位置之后又把旧帧拉回来。
  private var seekGeneration = 0
  /// 诊断：PiP 轻量模式。开启时按 PiP 窗口尺寸渲染，而不是源分辨率。
  /// `pipLiteModeRequested` 只在主线程读写，`pipLiteMode` 只在 `frameQueue`
  /// 上读写，避免 copy() 与 update() 竞争。
  private var pipLiteModeRequested = true
  private var pipLiteMode = true
  /// Whether a frame has been enqueued, PiP shows a black window otherwise.
  private var hasFrame = false

  // Accessed on `frameQueue` only.
  private let frameQueue = DispatchQueue(label: "com.example.piliplus.pip.frame")
  private let ciContext = CIContext(options: [
    .workingColorSpace: NSNull(),
    .outputColorSpace: NSNull(),
    .cacheIntermediates: false,
  ])
  private var pool: CVPixelBufferPool?
  private var poolSize = CGSize.zero
  /// Same-format copy pool for the direct-enqueue path (no CoreImage).
  private var directPool: CVPixelBufferPool?
  private var directPoolSize = CGSize.zero
  private var directPoolFormat: OSType = 0
  private var formatDescription: CMVideoFormatDescription?
  /// Size of the PiP window in pixels, zero until known.
  private var renderSize = CGSize.zero

  // 像素指纹诊断。PiP 卡在同一帧时，position/声音照常前进，只有 texture
  // 内容不变；这里直接对每帧 source/output 取样校验和，用 identicalRun
  // 证明「到底是不是同一张画面」。以下字段只在 `frameQueue` 上读写。
  private var lastSourceHash: UInt32 = 0
  private var hasSourceHash = false
  private var identicalRun = 0
  private var totalFingerprintFrames = 0
  private var identicalRunsSum = 0
  private var lastOutputHash: UInt32 = 0
  private var hasOutputHash = false
  private var verdictWritten = false
  /// 只在兜底渲染尺寸变化时写一次，避免每帧刷屏。
  private var lastFallbackLogSignature = ""

  init(textureId: Int64, sendEvent: @escaping (String, Any?) -> Void) {
    let sourceView = SampleBufferView()
    let displayLayer = sourceView.layer as! AVSampleBufferDisplayLayer
    displayLayer.videoGravity = .resizeAspect
    var timebase: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    )
    // Every sample is marked DisplayImmediately, so frames are shown on
    // arrival instead of on a PTS timeline. Mode: displayImmediately with
    // controlTimebase=nil; the timebase object is kept for the PiP playback
    // delegate (setPlaying / skipByInterval) only.
    displayLayer.controlTimebase = nil

    self.textureId = textureId
    self.sendEvent = sendEvent
    self.sourceView = sourceView
    self.displayLayer = displayLayer
    self.timebase = timebase!
    super.init()
    PipTrace.log(
      "mode: displayImmediately, layerTimebase=nil, timebase=delegate-only "
        + "texture=\(textureId)"
    )

    controller = AVPictureInPictureController(
      contentSource: .init(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
    )
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    possibleObservation = controller.observe(\.isPictureInPicturePossible) {
      [weak self] pipController, _ in
      PipTrace.log(
        "observation: possible=\(pipController.isPictureInPicturePossible) "
          + "active=\(pipController.isPictureInPictureActive)"
      )
      DispatchQueue.main.async { self?.startIfPending() }
    }
    // The video is shown inline again once the app is back in the foreground.
    // Starting PiP also posts foreground notifications, and stopping it is
    // ignored until the scene is active, hence `didActivate` after background.
    observers = [
      NotificationCenter.default.addObserver(
        forName: UIScene.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        // Also posted while active when PiP stops.
        if UIApplication.shared.applicationState == .background {
          self?.enteredBackground = true
        }
      },
      NotificationCenter.default.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self, self.enteredBackground else { return }
        self.enteredBackground = false
        if self.controller.isPictureInPictureActive {
          self.stopRequested = true
          self.controller.stopPictureInPicture()
        }
      },
    ]
  }

  /// Places the (hidden) source layer where the player usually is, so the
  /// system's start/stop animation roughly matches the inline video.
  func configure(width: Double, height: Double) {
    guard let window = Self.hostWindow() else {
      PipTrace.log("configure: hostWindow nil -> give up")
      return
    }
    if sourceView.superview !== window {
      // Below the Flutter view: it must be in the window, but not visible.
      window.insertSubview(sourceView, at: 0)
    }
    let aspectRatio = width > 0 && height > 0 ? width / height : 16 / 9
    let bounds = window.bounds
    var size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
    if size.height > bounds.height {
      size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
    }
    let y =
      bounds.height > bounds.width
      ? window.safeAreaInsets.top : (bounds.height - size.height) / 2
    sourceView.frame = CGRect(
      x: (bounds.width - size.width) / 2,
      y: y,
      width: size.width,
      height: size.height
    )
    PipTrace.log(
      "configure: side=\(size.width)x\(size.height) inWindow=\(sourceView.superview === window) "
        + "possible=\(controller.isPictureInPicturePossible) hasFrame=\(hasFrame) "
        + "windowCount=\(Self.windowCount()) superview=\(String(describing: sourceView.superview))"
    )
    frameAvailable(force: true)
  }

  func update(_ args: [String: Any]) {
    if let lite = args["pipLite"] as? Bool, lite != pipLiteModeRequested {
      pipLiteModeRequested = lite
      frameQueue.async { [weak self] in
        guard let self else { return }
        self.pipLiteMode = lite
        // 尺寸路径变了：丢掉旧 pool，并等 didTransition 重新给出窗口尺寸；
        // 在它回来之前轻量模式用 sourceView.bounds 兜底。
        self.pool = nil
        self.poolSize = .zero
        self.renderSize = .zero
        PipTrace.log("lite-mode: enabled=\(lite)")
        DispatchQueue.main.async { self.frameAvailable(force: true) }
      }
    }
    let position = (args["position"] as? NSNumber)?.int64Value
    let buffering = args["isBuffering"] as? Bool ?? isBuffering
    let durationMs = (args["duration"] as? NSNumber)?.int64Value
    if let value = args["isPlaying"] as? Bool { isPlaying = value }
    if let value = args["isBuffering"] as? Bool { isBuffering = value }
    if let value = args["isLive"] as? Bool { isLive = value }
    if let value = durationMs {
      duration = CMTime(value: value, timescale: 1000)
    }
    if let value = (args["speed"] as? NSNumber)?.doubleValue { speed = value }
    PipTrace.log(
      "update: position=\(position.map { String($0) } ?? "nil")ms isPlaying=\(isPlaying) "
        + "isBuffering=\(buffering) speed=\(speed) "
        + "duration=\(durationMs.map { String($0) } ?? "nil")ms"
    )
    if let position {
      positionMs = position
      let rate = isPlaying && !buffering ? speed : 0
      let status = CMTimebaseSetRateAndAnchorTime(
        timebase,
        rate: rate,
        anchorTime: CMTime(value: position, timescale: 1000),
        immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock())
      )
      let timebaseTime = CMTimebaseGetTime(timebase)
      PipTrace.log(
        "timebase: rate=\(rate) time=\(timebaseTime.seconds) status=\(status) "
          + "anchor=\(position)ms"
      )
    }
    controller.invalidatePlaybackState()
  }

  /// Enters PiP and then leaves the app, so that the video only plays in the
  /// PiP window, as on Android where the whole activity becomes the window.
  func start() {
    guard !controller.isPictureInPictureActive else { return }
    pendingStart = true
    backgroundOnStart = true
    startIfPending()
    // Give up if PiP doesn't become possible shortly, so a stale request
    // doesn't start PiP unexpectedly later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self, self.pendingStart else { return }
      self.pendingStart = false
      self.backgroundOnStart = false
      self.sendEvent("onStateChanged", ["active": false, "error": "PiP is not possible"])
      self.onStop?()
    }
  }

  private func startIfPending() {
    PipTrace.log(
      "startIfPending: pending=\(pendingStart) hasFrame=\(hasFrame) "
        + "possible=\(controller.isPictureInPicturePossible)"
    )
    guard pendingStart, hasFrame, controller.isPictureInPicturePossible else { return }
    pendingStart = false
    controller.startPictureInPicture()
  }

  private func updateAutoEnter() {
    // AVKit may start PiP as soon as the app goes to background.
    controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter && hasFrame
  }

  func invalidate() {
    pendingStart = false
    pendingFrameRequested = false
    possibleObservation?.invalidate()
    observers.forEach(NotificationCenter.default.removeObserver)
    controller.delegate = nil
    if controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    }
    if isActive {
      isActive = false
      sendEvent("onStateChanged", ["active": false])
    }
    // The content source retains its playback delegate (`self`).
    controller.contentSource = nil
    sourceView.removeFromSuperview()
    PipTrace.log(
      "summary: textureCallbacks=\(textureCallbackCount) "
        + "frameInFlightDrops=\(frameInFlightDropCount) "
        + "throttleDrops=\(throttleDropCount) enqueued=\(enqueuedFrameCount) "
        + "shown=\(shownFrameCount) droppedOld=\(droppedOldFrameCount) "
        + "direct=\(directFrameCount) render=\(renderFrameCount)"
    )
    // 同步在 frameQueue 上取快照：tearDown() 随后会把 session 置空，
    // 异步闭包可能已经拿不到统计值。
    frameQueue.sync { writeVerdictIfNeeded() }
  }

  // MARK: Frames

  /// Must be called on the main thread.
  func frameAvailable(force: Bool = false) {
    let callbackTime = CACurrentMediaTime()
    textureCallbackCount += 1
    if lastTextureCallbackTime > 0 {
      let gapMs = Int((callbackTime - lastTextureCallbackTime) * 1000)
      if gapMs > 200 {
        PipTrace.log(
          "callback-gap: gapMs=\(gapMs) callbacks=\(textureCallbackCount)"
        )
      }
    }
    lastTextureCallbackTime = callbackTime
    if callbackWindowStart == 0 {
      callbackWindowStart = callbackTime
    }
    callbackWindowCount += 1
    let windowMs = (callbackTime - callbackWindowStart) * 1000
    if windowMs >= 1000 {
      let fps = Double(callbackWindowCount) * 1000 / windowMs
      PipTrace.log(
        "stat-fps: callbacks=\(callbackWindowCount) windowMs=\(Int(windowMs)) "
          + "fps=\(String(format: "%.1f", fps))"
      )
      callbackWindowStart = callbackTime
      callbackWindowCount = 0
    }
    guard let texture = TextureTracker.texture(for: textureId) else {
      // 这里返回意味着 textureId 对不上：画中画永远拿不到帧。
      PipTrace.log("frameAvailable: no texture for id=\(textureId) (this is fatal)")
      return
    }
    let now = CACurrentMediaTime()
    if !force && !isActive && now - lastFrameTime < Self.idleFrameInterval {
      throttleDropCount += 1
      return
    }
    lastFrameTime = now
    if frameInFlight {
      // latest-wins: remember that a newer frame is waiting; the old pending
      // frame is superseded and never rendered.
      if pendingFrameRequested {
        droppedOldFrameCount += 1
      }
      pendingFrameRequested = true
      return
    }
    guard let source = texture.copyPixelBuffer()?.takeRetainedValue() else {
      PipTrace.log("frameAvailable: copyPixelBuffer returned nil for id=\(textureId)")
      return
    }
    process(source)
  }

  /// Runs one frame on `frameQueue`. Must be called on the main thread.
  private func process(_ source: CVPixelBuffer) {
    frameInFlight = true
    frameInFlightSince = CACurrentMediaTime()
    frameGeneration &+= 1
    let generation = frameGeneration
    // didTransitionToRenderSize 在部分机型上一直给 0；轻量模式退化为
    // 按 sourceView 的视频区域尺寸渲染，避免每帧按源分辨率做 NV12→BGRA。
    // bounds 为 0 时依次退到父视图 / 宿主窗口，全部取不到才放弃缩放。
    let fallbackRenderSize = Self.fallbackRenderSize(for: sourceView)
    // A blocked copy/render/enqueue would otherwise leave the flag set and
    // silently drop every later frame without a trace.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self, self.frameInFlight, self.frameGeneration == generation else {
        return
      }
      let stuckMs = Int((CACurrentMediaTime() - self.frameInFlightSince) * 1000)
      self.frameInFlight = false
      PipTrace.log("watchdog: frameInFlight cleared after \(stuckMs)ms")
      self.startPendingFrame()
    }
    // The source buffer is reused by mpv a few frames later, so it is copied
    // (and downscaled if needed) instead of being handed to the layer as is.
    // isActive 只在主线程读写，先在这里快照，别在 frameQueue 上裸读。
    let active = isActive
    frameQueue.async { [weak self] in
      guard let self else { return }
      var stage = "copy"
      var enqueued = false
      var direct = false
      let sourceFormat = CVPixelBufferGetPixelFormatType(source)
      self.recordSourceFingerprint(source, active: active)
      let pixelBuffer: CVPixelBuffer?
      if Self.isDisplayableFormat(sourceFormat),
        let directCopy = self.copyDirect(source, stage: &stage)
      {
        pixelBuffer = directCopy
        direct = true
      } else {
        pixelBuffer = self.copy(
          source,
          fallbackRenderSize: fallbackRenderSize,
          stage: &stage
        )
      }
      PipTrace.log(
        "direct-enqueue: pixfmt=\(Self.pixelFormatName(sourceFormat)) "
          + "skipRender=\(direct ? "YES" : "NO") "
          + "src=\(CVPixelBufferGetWidth(source))x\(CVPixelBufferGetHeight(source))"
      )
      if let pixelBuffer,
        let sampleBuffer = self.makeSampleBuffer(pixelBuffer, stage: &stage)
      {
        enqueued = self.enqueue(sampleBuffer, stage: &stage)
      }
      let layerStatus = self.displayLayer.status.rawValue
      let ready = self.displayLayer.isReadyForMoreMediaData
      PipTrace.log(
        "frame: enqueued=\(enqueued) stage=\(stage) direct=\(direct ? "YES" : "NO") "
          + "layerStatus=\(layerStatus) "
          + "ready=\(ready) size=\(CVPixelBufferGetWidth(source))x"
          + "\(CVPixelBufferGetHeight(source))"
      )
      DispatchQueue.main.async {
        guard self.frameGeneration == generation else { return }
        self.frameInFlight = false
        if enqueued {
          self.enqueuedFrameCount += 1
          self.shownFrameCount += 1
        }
        if direct {
          self.directFrameCount += 1
        } else {
          self.renderFrameCount += 1
        }
        if enqueued && !self.hasFrame {
          self.hasFrame = true
          self.updateAutoEnter()
          self.startIfPending()
        }
        self.startPendingFrame()
      }
    }
  }

  /// Main thread only. Picks up the newest frame that arrived while busy.
  private func startPendingFrame() {
    guard pendingFrameRequested else { return }
    pendingFrameRequested = false
    // Pull the current texture buffer instead of holding on to the frame that
    // was pending: mpv reuses that buffer, so its contents may already be
    // overwritten by the time the previous frame finishes.
    guard
      let texture = TextureTracker.texture(for: textureId),
      let source = texture.copyPixelBuffer()?.takeRetainedValue()
    else {
      return
    }
    process(source)
  }

  private func copy(
    _ source: CVPixelBuffer,
    fallbackRenderSize: CGSize,
    stage: inout String
  ) -> CVPixelBuffer? {
    let started = CFAbsoluteTimeGetCurrent()
    let sourceWidth = Double(CVPixelBufferGetWidth(source))
    let sourceHeight = Double(CVPixelBufferGetHeight(source))
    var sizeMs = 0.0
    var poolMs = 0.0
    var pixelBufferMs = 0.0
    var renderMs = 0.0
    var outputWidth = 0
    var outputHeight = 0
    defer {
      let totalMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
      let details =
        "totalMs=\(totalMs) sizeMs=\(Int(sizeMs)) poolMs=\(Int(poolMs)) "
        + "pixelBufferMs=\(Int(pixelBufferMs)) renderMs=\(Int(renderMs)) "
        + "src=\(Int(sourceWidth))x\(Int(sourceHeight)) "
        + "out=\(outputWidth)x\(outputHeight) lite=\(pipLiteMode ? 1 : 0)"
      PipTrace.log("copy-timing: \(details)")
      let stages: [(String, Double)] = [
        ("size", sizeMs),
        ("pool", poolMs),
        ("pixelBuffer", pixelBufferMs),
        ("render", renderMs),
      ]
      for (name, ms) in stages where ms > 30 {
        PipTrace.log("copy-slow: stage=\(name) ms=\(Int(ms)) \(details)")
      }
    }

    stage = "size"
    guard sourceWidth > 0, sourceHeight > 0 else {
      PipTrace.log(
        "copy: zero source size \(CVPixelBufferGetWidth(source))x"
          + "\(CVPixelBufferGetHeight(source))"
      )
      return nil
    }
    // 轻量模式优先用 PiP 窗口尺寸；didTransition 一直给 0 时退化为
    // sourceView 的视频区域尺寸（点），让每帧最多只渲染窗口像素。
    var target = CGSize.zero
    var usedFallback = false
    if pipLiteMode {
      if renderSize.width > 0 && renderSize.height > 0 {
        target = renderSize
      } else {
        target = fallbackRenderSize
        usedFallback = true
      }
    } else if renderSize.width > 0 && renderSize.height > 0 {
      target = renderSize
    }
    var scale = min(1, Self.maxDimension / max(sourceWidth, sourceHeight))
    if target.width > 0 && target.height > 0 {
      // 等比缩放到窗口内（contain）：取两个方向的较小比例，避免为了
      // 铺满一边把另一边也放大，输出像素反而超过窗口尺寸。
      scale = min(
        scale,
        min(target.width / sourceWidth, target.height / sourceHeight)
      )
    }
    let size = CGSize(
      width: (sourceWidth * scale).rounded(),
      height: (sourceHeight * scale).rounded()
    )
    outputWidth = Int(size.width)
    outputHeight = Int(size.height)
    if usedFallback && target.width > 0 && target.height > 0 {
      let signature =
        "\(Int(target.width))x\(Int(target.height))->"
        + "\(outputWidth)x\(outputHeight)"
      if signature != lastFallbackLogSignature {
        lastFallbackLogSignature = signature
        PipTrace.log(
          "fallback-render: target=\(Int(target.width))x\(Int(target.height)) "
            + "src=\(Int(sourceWidth))x\(Int(sourceHeight)) "
            + "out=\(outputWidth)x\(outputHeight) lite=\(pipLiteMode ? 1 : 0)"
        )
      }
    }
    sizeMs = (CFAbsoluteTimeGetCurrent() - started) * 1000

    let poolStarted = CFAbsoluteTimeGetCurrent()
    if pool == nil || poolSize != size {
      pool = nil
      poolSize = size
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: Int(size.width),
        kCVPixelBufferHeightKey: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      let status = CVPixelBufferPoolCreate(
        nil,
        nil,
        attributes as CFDictionary,
        &pool
      )
      if status != kCVReturnSuccess || pool == nil {
        pool = nil
        PipTrace.log(
          "copy: pool create failed status=\(status) "
            + "size=\(Int(size.width))x\(Int(size.height))"
        )
        return nil
      }
    }
    poolMs = (CFAbsoluteTimeGetCurrent() - poolStarted) * 1000
    guard let pool else { return nil }

    stage = "pixelBuffer"
    let pixelBufferStarted = CFAbsoluteTimeGetCurrent()
    var output: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
    guard let output else {
      PipTrace.log(
        "copy: pixel buffer create failed status=\(status) "
          + "size=\(Int(size.width))x\(Int(size.height))"
      )
      return nil
    }
    pixelBufferMs = (CFAbsoluteTimeGetCurrent() - pixelBufferStarted) * 1000

    stage = "render"
    let renderStarted = CFAbsoluteTimeGetCurrent()
    var image = CIImage(cvPixelBuffer: source)
    if scale < 1 {
      image = image.transformed(
        by: CGAffineTransform(
          scaleX: size.width / sourceWidth,
          y: size.height / sourceHeight
        )
      )
    }
    ciContext.render(image, to: output)
    renderMs = (CFAbsoluteTimeGetCurrent() - renderStarted) * 1000
    recordOutputFingerprint(output)
    stage = "done"
    return output
  }

  /// Pixel formats `AVSampleBufferDisplayLayer` can show without conversion.
  private static func isDisplayableFormat(_ format: OSType) -> Bool {
    switch format {
    case kCVPixelFormatType_32BGRA,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      return true
    default:
      return false
    }
  }

  private static func pixelFormatName(_ format: OSType) -> String {
    let bytes = [
      UInt8((format >> 24) & 0xFF),
      UInt8((format >> 16) & 0xFF),
      UInt8((format >> 8) & 0xFF),
      UInt8(format & 0xFF),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
      return String(bytes: bytes, encoding: .ascii)
        ?? String(format: "0x%08X", format)
    }
    return String(format: "0x%08X", format)
  }

  /// Copies the source frame into a pooled buffer of the same pixel format,
  /// so the display layer can scale it via `videoGravity` without a CoreImage
  /// render. The copy keeps mpv's recycled source buffer from changing under
  /// the layer after enqueue.
  private func copyDirect(
    _ source: CVPixelBuffer,
    stage: inout String
  ) -> CVPixelBuffer? {
    let started = CFAbsoluteTimeGetCurrent()
    let format = CVPixelBufferGetPixelFormatType(source)
    let width = CVPixelBufferGetWidth(source)
    let height = CVPixelBufferGetHeight(source)
    let size = CGSize(width: CGFloat(width), height: CGFloat(height))
    let formatName = Self.pixelFormatName(format)

    stage = "direct-pool"
    if directPool == nil || directPoolSize != size || directPoolFormat != format {
      directPool = nil
      directPoolSize = size
      directPoolFormat = format
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: format,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      let status = CVPixelBufferPoolCreate(
        nil,
        nil,
        attributes as CFDictionary,
        &directPool
      )
      if status != kCVReturnSuccess || directPool == nil {
        directPool = nil
        PipTrace.log(
          "direct-copy: pool create failed status=\(status) pixfmt=\(formatName)"
        )
        return nil
      }
    }
    guard let pool = directPool else { return nil }

    stage = "direct-copy"
    var output: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
    guard let output else {
      PipTrace.log(
        "direct-copy: pixel buffer create failed status=\(status) "
          + "pixfmt=\(formatName)"
      )
      return nil
    }
    guard copyContents(from: source, to: output) else {
      PipTrace.log("direct-copy: content copy failed pixfmt=\(formatName)")
      return nil
    }
    let totalMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
    let details =
      "pixfmt=\(formatName) src=\(width)x\(height) "
      + "directMs=\(totalMs) lite=\(pipLiteMode ? 1 : 0)"
    PipTrace.log("copy-timing: direct \(details)")
    if totalMs > 30 {
      PipTrace.log("copy-slow: stage=direct-copy ms=\(totalMs) \(details)")
    }
    recordOutputFingerprint(output)
    stage = "done"
    return output
  }

  /// Row copy between buffers of the same format and dimensions. No colour
  /// conversion, no scaling.
  private func copyContents(
    from source: CVPixelBuffer,
    to destination: CVPixelBuffer
  ) -> Bool {
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
      return false
    }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
      return false
    }
    defer { CVPixelBufferUnlockBaseAddress(destination, []) }
    let planar = CVPixelBufferIsPlanar(source)
    guard planar == CVPixelBufferIsPlanar(destination) else { return false }
    if planar {
      let planeCount = CVPixelBufferGetPlaneCount(source)
      guard planeCount == CVPixelBufferGetPlaneCount(destination) else {
        return false
      }
      for plane in 0..<planeCount {
        guard
          let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
          let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
        else { return false }
        let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let dstStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
        let rows = min(
          CVPixelBufferGetHeightOfPlane(source, plane),
          CVPixelBufferGetHeightOfPlane(destination, plane)
        )
        let rowBytes = min(srcStride, dstStride)
        if srcStride == dstStride {
          memcpy(dst, src, rowBytes * rows)
        } else {
          for row in 0..<rows {
            memcpy(
              dst.advanced(by: row * dstStride),
              src.advanced(by: row * srcStride),
              rowBytes
            )
          }
        }
      }
    } else {
      guard
        let src = CVPixelBufferGetBaseAddress(source),
        let dst = CVPixelBufferGetBaseAddress(destination)
      else { return false }
      let srcStride = CVPixelBufferGetBytesPerRow(source)
      let dstStride = CVPixelBufferGetBytesPerRow(destination)
      let rows = min(
        CVPixelBufferGetHeight(source),
        CVPixelBufferGetHeight(destination)
      )
      let rowBytes = min(srcStride, dstStride)
      if srcStride == dstStride {
        memcpy(dst, src, rowBytes * rows)
      } else {
        for row in 0..<rows {
          memcpy(
            dst.advanced(by: row * dstStride),
            src.advanced(by: row * srcStride),
            rowBytes
          )
        }
      }
    }
    return true
  }

  /// 32 位 FNV-1a。固定步长取样，最多 512 个点；大缓冲时按总字节数
  /// 放大步长，保证覆盖整帧，而不是只读开头那一段。
  private func pixelFingerprint(_ buffer: CVPixelBuffer) -> UInt32? {
    let lockStatus = CVPixelBufferLockBaseAddress(buffer, .readOnly)
    guard lockStatus == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    // 源帧通常是 NV12 平面格式；只在 plane 0（亮度）里取样，避免跨平面
    // 读到不连续的内存。BGRA 输出则是单块数据，按 dataSize 取样。
    let base: UnsafeMutableRawPointer?
    let limit: Int
    if CVPixelBufferIsPlanar(buffer) {
      base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
      limit = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        * CVPixelBufferGetHeightOfPlane(buffer, 0)
    } else {
      base = CVPixelBufferGetBaseAddress(buffer)
      limit = CVPixelBufferGetDataSize(buffer)
    }
    guard let base, limit > 0 else { return nil }
    let stride = max(4096, limit / 512)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var hash: UInt32 = 2166136261
    var offset = 0
    var samples = 0
    while offset < limit && samples < 512 {
      hash = (hash ^ UInt32(bytes[offset])) &* 16777619
      samples += 1
      offset += stride
    }
    return hash
  }

  /// 对源 texture 的帧算指纹，统计连续相同帧长度。达到 5/20/60 时各写
  /// 一条 stale-source；达到 5 且 PiP 活跃时先 flush 一次显示层，用来
  /// 区分「显示层缓存」与「源 texture 冻结」。
  private func recordSourceFingerprint(_ source: CVPixelBuffer, active: Bool) {
    guard let hash = pixelFingerprint(source) else {
      PipTrace.log("fingerprint: source lock failed")
      return
    }
    totalFingerprintFrames += 1
    let same = hasSourceHash && hash == lastSourceHash
    if same {
      identicalRun += 1
    } else {
      identicalRunsSum += identicalRun
      identicalRun = 0
      hasSourceHash = true
      lastSourceHash = hash
    }
    guard same else { return }
    if identicalRun == 5 || identicalRun == 20 || identicalRun == 60 {
      PipTrace.log(
        "stale-source: run=\(identicalRun) "
          + "hash=\(String(format: "%08X", hash)) active=\(active ? "YES" : "NO")"
      )
      if active {
        flushForStale(run: identicalRun)
      }
    }
  }

  /// 对 render 后的 output 算指纹。每帧都写一次，true/false 直接对应
  /// 「这一帧和上一帧的渲染结果是否不同」。
  private func recordOutputFingerprint(_ output: CVPixelBuffer) {
    guard let hash = pixelFingerprint(output) else {
      PipTrace.log("out-hash-changed: false (lock failed)")
      return
    }
    let changed = !hasOutputHash || hash != lastOutputHash
    hasOutputHash = true
    lastOutputHash = hash
    PipTrace.log("out-hash-changed: \(changed)")
  }

  private func flushForStale(run: Int) {
    if #available(iOS 17.0, *) {
      displayLayer.sampleBufferRenderer.flush()
    } else {
      displayLayer.flush()
    }
    PipTrace.log("flush-on-stale: run=\(run)")
  }

  /// seek 后显示层里还排着旧 PTS 的样本；不 flush 的话新帧会排在旧
  /// 时间线上，表现为一直停在 seek 前那一帧。
  private func flushForSeek() {
    if #available(iOS 17.0, *) {
      displayLayer.sampleBufferRenderer.flush()
    } else {
      displayLayer.flush()
    }
    PipTrace.log("pip-seek-flush: asked")
  }

  /// 重置 PiP 用的时基并重新锚定。layer 本身不接 controlTimebase，
  /// 这里只保证 delegate 报告的 position/rate 与真实播放位置一致。
  @discardableResult
  private func resetTimebase(targetMs: Int64, reason: String) -> OSStatus {
    let target = CMTime(value: targetMs, timescale: 1000)
    CMTimebaseSetTime(timebase, time: target)
    let rate = isPlaying && !isBuffering ? speed : 0
    let status = CMTimebaseSetRateAndAnchorTime(
      timebase,
      rate: rate,
      anchorTime: target,
      immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock())
    )
    let current = CMTimebaseGetTime(timebase)
    PipTrace.log(
      "timebase-reset: reason=\(reason) rate=\(rate) target=\(targetMs)ms "
        + "time=\(current.seconds) status=\(status)"
    )
    return status
  }

  /// seek / 恢复播放后主动拉几次最新 texture。不能只等下一次回调：
  /// mpv 已经暂停出帧时，显示层不会自己醒来。
  private func requestFramesAfterReset(generation: Int) {
    let delays: [Double] = [0, 0.05, 0.15, 0.35, 0.7]
    for delay in delays {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, self.seekGeneration == generation else { return }
        self.frameAvailable(force: true)
      }
    }
  }

  /// 会话结束时汇总：total 是参与比对的帧数，identicalRunsSum 是所有
  /// 「与上一帧相同」的帧数，distinctApprox 是不同画面的近似数量。
  private func writeVerdictIfNeeded() {
    guard !verdictWritten else { return }
    verdictWritten = true
    let total = totalFingerprintFrames
    let runsSum = identicalRunsSum + identicalRun
    let distinct = max(0, total - runsSum)
    PipTrace.log(
      "verdict-frames: total=\(total) identicalRunsSum=\(runsSum) "
        + "distinctApprox=\(distinct)"
    )
  }

  private func makeSampleBuffer(
    _ pixelBuffer: CVPixelBuffer,
    stage: inout String
  ) -> CMSampleBuffer? {
    stage = "format"
    let matches =
      formatDescription.map {
        CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer)
      } ?? false
    if !matches {
      formatDescription = nil
      let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      )
      if status != 0 {
        PipTrace.log("makeSampleBuffer: format description failed status=\(status)")
      }
    }
    guard let formatDescription else { return nil }

    stage = "sample"
    let pts = CMTimebaseGetTime(timebase)
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: pts,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else {
      PipTrace.log(
        "makeSampleBuffer: sample buffer failed status=\(status) pts=\(pts.seconds)"
      )
      return nil
    }
    let now = CMTimebaseGetTime(timebase)
    let deltaMs =
      pts.isValid && now.isValid
      ? CMTimeSubtract(now, pts).seconds * 1000 : Double.nan
    PipTrace.log(
      "pts: value=\(pts.seconds) timebase=\(now.seconds) deltaMs=\(deltaMs)"
    )

    // Frames are already paced by mpv.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ), CFArrayGetCount(attachments) > 0 {
      let dict = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        dict,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    stage = "done"
    return sampleBuffer
  }

  private func enqueue(_ sampleBuffer: CMSampleBuffer, stage: inout String) -> Bool {
    stage = "enqueue"
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let before = CMTimebaseGetTime(timebase)
    let ptsAgeMs =
      pts.isValid && before.isValid
      ? CMTimeSubtract(before, pts).seconds * 1000 : Double.nan
    let began = CACurrentMediaTime()
    let enqueued: Bool
    if #available(iOS 17.0, *) {
      let renderer = displayLayer.sampleBufferRenderer
      PipTrace.log(
        "enqueue(before): isReadyForMoreMediaData="
          + "\(renderer.isReadyForMoreMediaData) status=\(renderer.status.rawValue) "
          + "layerStatus=\(displayLayer.status.rawValue) "
          + "requiresFlush=\(renderer.requiresFlushToResumeDecoding) "
          + "pts=\(pts.seconds) ptsAgeMs=\(ptsAgeMs)"
      )
      if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
        renderer.flush()
      }
      renderer.enqueue(sampleBuffer)
      enqueued = renderer.status != .failed
      let elapsedMs = Int((CACurrentMediaTime() - began) * 1000)
      PipTrace.log(
        "enqueue(after): isReadyForMoreMediaData="
          + "\(renderer.isReadyForMoreMediaData) status=\(renderer.status.rawValue) "
          + "layerStatus=\(displayLayer.status.rawValue) enqueued=\(enqueued) "
          + "elapsedMs=\(elapsedMs)"
      )
    } else {
      PipTrace.log(
        "enqueue(before): isReadyForMoreMediaData="
          + "\(displayLayer.isReadyForMoreMediaData) "
          + "status=\(displayLayer.status.rawValue) "
          + "requiresFlush=\(displayLayer.requiresFlushToResumeDecoding) "
          + "pts=\(pts.seconds) ptsAgeMs=\(ptsAgeMs)"
      )
      if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
        displayLayer.flush()
      }
      displayLayer.enqueue(sampleBuffer)
      enqueued = displayLayer.status != .failed
      let elapsedMs = Int((CACurrentMediaTime() - began) * 1000)
      PipTrace.log(
        "enqueue(after): isReadyForMoreMediaData="
          + "\(displayLayer.isReadyForMoreMediaData) "
          + "status=\(displayLayer.status.rawValue) enqueued=\(enqueued) "
          + "elapsedMs=\(elapsedMs)"
      )
    }
    if enqueued {
      stage = "done"
    }
    return enqueued
  }

  /// Same as the home gesture. There is no public API for this, `suspend` is
  /// a private method of `UIApplication`.
  private static func moveToBackground() {
    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
  }

  private static func hostWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    return windows.first { $0.rootViewController is FlutterViewController }
      ?? windows.first { $0.isKeyWindow }
  }

  /// 兜底渲染尺寸：sourceView 自己的 bounds 优先，依次退到父视图和宿主
  /// 窗口。must be called on the main thread。
  private static func fallbackRenderSize(for view: UIView) -> CGSize {
    let candidates: [CGSize?] = [
      view.bounds.size,
      view.superview?.bounds.size,
      hostWindow()?.bounds.size,
    ]
    for case let size? in candidates where size.width > 0 && size.height > 0 {
      return size
    }
    return .zero
  }

  /// 宿主窗口总数。configure 后如果 sourceView 没进树，这里通常是 0 或
  /// 只剩一个空窗口，和 superview 描述一起就能区分「没插进去」与「插错层」。
  private static func windowCount() -> Int {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .reduce(0) { $0 + $1.windows.count }
  }
}

@available(iOS 15.0, *)
extension PipSession: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isActive = true
    stopRequested = false
    restoring = false
    PipTrace.log("WILL start: sourceViewInTree=\(sourceView.superview != nil)")
    frameAvailable(force: true)
    sendEvent("onStateChanged", ["active": true])
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    PipTrace.log("DID start: layerInTree=\(displayLayer.superlayer != nil) hasFrame=\(hasFrame)")
    if backgroundOnStart {
      backgroundOnStart = false
      Self.moveToBackground()
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    isActive = false
    backgroundOnStart = false
    PipTrace.log("FAILED to start: \(error.localizedDescription)")
    sendEvent("onStateChanged", ["active": false, "error": error.localizedDescription])
    DispatchQueue.main.async { [weak self] in self?.onStop?() }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    PipTrace.log(
      "restore requested: active=\(isActive) sourceViewInTree=\(sourceView.superview != nil)"
    )
    restoring = true
    completionHandler(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isActive = false
    // Neither restored nor stopped by the app: closed from the PiP window.
    let closed = !restoring && !stopRequested
    PipTrace.log(
      "DID stop: closed=\(closed) restoring=\(restoring) stopRequested=\(stopRequested) "
        + "sourceViewInTree=\(sourceView.superview != nil)"
    )
    stopRequested = false
    restoring = false
    sendEvent("onStateChanged", ["active": false, "closed": closed])
    DispatchQueue.main.async { [weak self] in self?.onStop?() }
  }
}

@available(iOS 15.0, *)
extension PipSession: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    isPlaying = playing
    let rate = playing && !isBuffering ? speed : 0
    if playing {
      // 从暂停恢复时把时基重新锚到当前播放位置，不能只 SetRate：
      // 暂停期间 Dart 推来的 position 可能已经落后，直接恢复会跳。
      resetTimebase(targetMs: max(0, positionMs), reason: "setplaying")
    } else {
      let status = CMTimebaseSetRate(timebase, rate: 0)
      let current = CMTimebaseGetTime(timebase)
      PipTrace.log(
        "timebase-reset: reason=setplaying-pause rate=0 "
          + "time=\(current.seconds) status=\(status)"
      )
    }
    PipTrace.log(
      "pip-setplaying: playing=\(playing) rate=\(rate) pos=\(positionMs)ms "
        + "buffering=\(isBuffering) speed=\(speed)"
    )
    pictureInPictureController.invalidatePlaybackState()
    sendEvent("setPlaying", playing)
    if playing {
      // Dart 侧恢复 media_kit 后不一定马上有 texture 回调；和 seek 一样
      // 主动拉几次帧，确保 PiP 不停在暂停画面。
      seekGeneration &+= 1
      requestFramesAfterReset(generation: seekGeneration)
    }
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    if isLive || !(duration.seconds > 0) {
      return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    return CMTimeRange(start: .zero, duration: duration)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    !isPlaying
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    // Reported in points.
    let scale = max(sourceView.traitCollection.displayScale, 1)
    let size = CGSize(
      width: Double(newRenderSize.width) * scale,
      height: Double(newRenderSize.height) * scale
    )
    frameQueue.async { [weak self] in
      guard let self else { return }
      // 轻量模式直接用窗口点数作为渲染像素，强制做一次真正的缩小；
      // 关闭时保持原来的「点数 × displayScale」行为，便于 A/B。
      self.renderSize = self.pipLiteMode
        ? CGSize(
          width: Double(newRenderSize.width),
          height: Double(newRenderSize.height)
        )
        : size
      PipTrace.log(
        "render-size: reported=\(newRenderSize.width)x\(newRenderSize.height) "
          + "used=\(Int(self.renderSize.width))x\(Int(self.renderSize.height)) "
          + "lite=\(self.pipLiteMode ? 1 : 0)"
      )
      DispatchQueue.main.async { self.frameAvailable(force: true) }
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    let deltaSeconds = skipInterval.seconds
    let deltaMs =
      deltaSeconds.isFinite ? Int64((deltaSeconds * 1000).rounded()) : 0
    let currentMs = max(0, positionMs)
    var targetMs = currentMs + deltaMs
    let durationSeconds = duration.seconds
    let durationMs =
      durationSeconds > 0 && durationSeconds.isFinite
      ? Int64((durationSeconds * 1000).rounded()) : 0
    if !isLive && durationMs > 0 {
      targetMs = min(max(0, targetMs), durationMs)
    } else {
      targetMs = max(0, targetMs)
    }
    positionMs = targetMs
    let status = resetTimebase(targetMs: targetMs, reason: "skip")
    flushForSeek()
    seekGeneration &+= 1
    let generation = seekGeneration
    let rate = isPlaying && !isBuffering ? speed : 0
    PipTrace.log(
      "pip-seek: delta=\(deltaMs) target=\(targetMs) current=\(currentMs) "
        + "duration=\(durationMs) rate=\(rate) status=\(status)"
    )
    // 原生不能直接 seek mpv：把目标位置交给 Dart，由 media_kit 真正执行。
    // Dart 侧 seek 完成后会回传 position，帧回调继续供 PiP。
    sendEvent("skip", ["delta": Int(deltaMs), "target": Int(targetMs)])
    requestFramesAfterReset(generation: generation)
    completionHandler()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    false
  }
}

private final class SampleBufferView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

// MARK: - Texture tracking

/// Hooks the engine's `FlutterTextureRegistry` to keep track of registered
/// textures and to observe their frame updates. Main thread only.
private enum TextureTracker {
  private final class WeakTexture {
    weak var value: FlutterTexture?
    init(_ value: FlutterTexture) { self.value = value }
  }

  private static var textures = [Int64: WeakTexture]()
  private static var installed = false

  static var onFrameAvailable: ((Int64) -> Void)?

  static func texture(for textureId: Int64) -> FlutterTexture? {
    textures[textureId]?.value
  }

  static func install(on registry: FlutterTextureRegistry) {
    guard !installed, let cls = object_getClass(registry) else { return }
    installed = true

    let registerSelector = NSSelectorFromString("registerTexture:")
    hook(cls, registerSelector) { original in
      typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Int64
      let function = unsafeBitCast(original, to: Function.self)
      let block: @convention(block) (AnyObject, AnyObject) -> Int64 = { this, texture in
        let textureId = function(this, registerSelector, texture)
        if let texture = texture as? FlutterTexture {
          Self.textures = Self.textures.filter { $0.value.value != nil }
          Self.textures[textureId] = WeakTexture(texture)
        }
        return textureId
      }
      return unsafeBitCast(block, to: AnyObject.self)
    }

    let frameAvailableSelector = NSSelectorFromString("textureFrameAvailable:")
    hook(cls, frameAvailableSelector) { original in
      typealias Function = @convention(c) (AnyObject, Selector, Int64) -> Void
      let function = unsafeBitCast(original, to: Function.self)
      let block: @convention(block) (AnyObject, Int64) -> Void = { this, textureId in
        function(this, frameAvailableSelector, textureId)
        Self.onFrameAvailable?(textureId)
      }
      return unsafeBitCast(block, to: AnyObject.self)
    }
  }

  private static func hook(
    _ cls: AnyClass,
    _ selector: Selector,
    _ makeBlock: (IMP) -> AnyObject
  ) {
    guard let method = class_getInstanceMethod(cls, selector) else {
      NSLog("PipPlugin: \(cls) does not respond to \(selector)")
      return
    }
    let imp = imp_implementationWithBlock(makeBlock(method_getImplementation(method)))
    // Add an override if the method is inherited, so the superclass is untouched.
    if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
      method_setImplementation(method, imp)
    }
  }
}
