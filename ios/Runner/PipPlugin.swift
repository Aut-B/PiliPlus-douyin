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
  private var formatDescription: CMVideoFormatDescription?
  /// Size of the PiP window in pixels, zero until known.
  private var renderSize = CGSize.zero

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
      [weak self] _, _ in
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
        + "possible=\(controller.isPictureInPicturePossible) hasFrame=\(hasFrame)"
    )
    frameAvailable(force: true)
  }

  func update(_ args: [String: Any]) {
    let position = (args["position"] as? NSNumber)?.int64Value
    let isBuffering = args["isBuffering"] as? Bool ?? false
    let durationMs = (args["duration"] as? NSNumber)?.int64Value
    if let value = args["isPlaying"] as? Bool { isPlaying = value }
    if let value = args["isLive"] as? Bool { isLive = value }
    if let value = durationMs {
      duration = CMTime(value: value, timescale: 1000)
    }
    if let value = (args["speed"] as? NSNumber)?.doubleValue { speed = value }
    PipTrace.log(
      "update: position=\(position.map { String($0) } ?? "nil")ms isPlaying=\(isPlaying) "
        + "isBuffering=\(isBuffering) speed=\(speed) "
        + "duration=\(durationMs.map { String($0) } ?? "nil")ms"
    )
    if let position {
      positionMs = position
      let rate = isPlaying && !isBuffering ? speed : 0
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
        + "throttleDrops=\(throttleDropCount) enqueued=\(enqueuedFrameCount)"
    )
  }

  // MARK: Frames

  /// Must be called on the main thread.
  func frameAvailable(force: Bool = false) {
    textureCallbackCount += 1
    guard !frameInFlight else {
      frameInFlightDropCount += 1
      return
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
    guard let source = texture.copyPixelBuffer()?.takeRetainedValue() else {
      PipTrace.log("frameAvailable: copyPixelBuffer returned nil for id=\(textureId)")
      return
    }
    lastFrameTime = now
    frameInFlight = true
    frameInFlightSince = CACurrentMediaTime()
    frameGeneration &+= 1
    let generation = frameGeneration
    // A blocked copy/render/enqueue would otherwise leave the flag set and
    // silently drop every later frame without a trace.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self, self.frameInFlight, self.frameGeneration == generation else {
        return
      }
      let stuckMs = Int((CACurrentMediaTime() - self.frameInFlightSince) * 1000)
      self.frameInFlight = false
      PipTrace.log("watchdog: frameInFlight cleared after \(stuckMs)ms")
    }
    // The source buffer is reused by mpv a few frames later, so it is copied
    // (and downscaled if needed) instead of being handed to the layer as is.
    frameQueue.async { [weak self] in
      guard let self else { return }
      var stage = "copy"
      var enqueued = false
      if let copy = self.copy(source, stage: &stage),
        let sampleBuffer = self.makeSampleBuffer(copy, stage: &stage)
      {
        enqueued = self.enqueue(sampleBuffer, stage: &stage)
      }
      let layerStatus = self.displayLayer.status.rawValue
      let ready = self.displayLayer.isReadyForMoreMediaData
      PipTrace.log(
        "frame: enqueued=\(enqueued) stage=\(stage) layerStatus=\(layerStatus) "
          + "ready=\(ready) size=\(CVPixelBufferGetWidth(source))x"
          + "\(CVPixelBufferGetHeight(source))"
      )
      DispatchQueue.main.async {
        guard self.frameGeneration == generation else { return }
        self.frameInFlight = false
        if enqueued {
          self.enqueuedFrameCount += 1
        }
        if enqueued && !self.hasFrame {
          self.hasFrame = true
          self.updateAutoEnter()
          self.startIfPending()
        }
      }
    }
  }

  private func copy(_ source: CVPixelBuffer, stage: inout String) -> CVPixelBuffer? {
    stage = "size"
    let sourceWidth = Double(CVPixelBufferGetWidth(source))
    let sourceHeight = Double(CVPixelBufferGetHeight(source))
    guard sourceWidth > 0, sourceHeight > 0 else {
      PipTrace.log(
        "copy: zero source size \(CVPixelBufferGetWidth(source))x"
          + "\(CVPixelBufferGetHeight(source))"
      )
      return nil
    }
    var scale = min(1, Self.maxDimension / max(sourceWidth, sourceHeight))
    if renderSize.width > 0 && renderSize.height > 0 {
      // No need for more pixels than the PiP window has.
      scale = min(
        scale,
        max(renderSize.width / sourceWidth, renderSize.height / sourceHeight)
      )
    }
    let size = CGSize(
      width: (sourceWidth * scale).rounded(),
      height: (sourceHeight * scale).rounded()
    )

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
    guard let pool else { return nil }

    stage = "pixelBuffer"
    var output: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
    guard let output else {
      PipTrace.log(
        "copy: pixel buffer create failed status=\(status) "
          + "size=\(Int(size.width))x\(Int(size.height))"
      )
      return nil
    }

    stage = "render"
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
    stage = "done"
    return output
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
    restoring = true
    completionHandler(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isActive = false
    // Neither restored nor stopped by the app: closed from the PiP window.
    let closed = !restoring && !stopRequested
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
    CMTimebaseSetRate(timebase, rate: playing ? speed : 0)
    pictureInPictureController.invalidatePlaybackState()
    sendEvent("setPlaying", playing)
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
      self?.renderSize = size
      DispatchQueue.main.async { self?.frameAvailable(force: true) }
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    let current = CMTime(value: positionMs, timescale: 1000)
    let target = CMTimeClampToRange(
      CMTimeAdd(current, skipInterval),
      range: CMTimeRange(start: .zero, duration: duration)
    )
    positionMs = Int64((target.seconds * 1000).rounded())
    CMTimebaseSetTime(timebase, time: target)
    sendEvent("skip", Int((skipInterval.seconds * 1000).rounded()))
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
