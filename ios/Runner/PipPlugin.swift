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
    TextureTracker.onTextureUnregistered = { [weak self] textureId in
      // The engine calls this on the platform thread, but keep the hop so
      // session state is only touched on main.
      DispatchQueue.main.async {
        guard #available(iOS 15.0, *), let session = self?.session,
          session.textureId == textureId
        else { return }
        session.surfaceSourceUnregistered()
      }
    }
    TextureTracker.onTextureRegistered = { [weak self] textureId in
      // 播放器重建会注册一个新 texture；PiP 窗口还在（或正 hold 最后一帧）时
      // 自动把源切到新纹理，否则会一直冻在旧 id 的最后一帧。
      DispatchQueue.main.async {
        guard #available(iOS 15.0, *), let session = self?.session else { return }
        guard session.textureId != textureId, session.pipActiveOrHolding else {
          return
        }
        PipTrace.log(
          "pip-surface: auto-retarget on texture-registered \(session.textureId) -> \(textureId)"
        )
        session.retarget(to: textureId, reason: "texture-registered")
      }
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
      if let current = self.session {
        if current.textureId != textureId {
          // A player rebuild changes the Flutter texture id while PiP is on
          // screen. Tearing the controller down here drops the PiP window and
          // leaves only the audio track alive. Keep the controller/layer and
          // retarget the frame source; the last frame stays visible until the
          // new texture produces its first frame.
          current.retarget(to: textureId, reason: "enter")
        } else {
          current.releaseSurfaceHold(reason: "enter-same-texture")
        }
        session = current
      } else {
        session = PipSession(textureId: textureId) { [weak self] method, arguments in
          self?.channel.invokeMethod(method, arguments: arguments)
        }
        session.onStop = { [weak self, weak session] in
          // Keep the session alive while armed for auto-enter.
          guard let self, let session, self.session === session,
            session.shouldTeardownOnStop
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
    case "requestStart":
      // 由 Dart 在按 Home 退后台时显式请求。sample buffer contentSource
      // 不会因为 canStartPictureInPictureAutomaticallyFromInline 自动起小窗。
      session?.requestStart()
      result(nil)
    case "disableAutoEnter":
      if let session {
        session.noteAutoEnterDisabled()
        session.autoEnter = false
        if !session.isActive && !session.shouldKeepOnDisarm {
          tearDown()
        }
      }
      result(nil)
    case "dispose":
      if let session, session.deferTeardownForDispose() {
        PipTrace.log("dispose: deferred while PiP surface is active")
      } else {
        tearDown()
      }
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
  /// 单文件上限 8MB；超过后只保留末尾一半，避免逐帧日志无限增长。
  private static let maxBytes = 8 * 1024 * 1024
  private static let keepBytes = maxBytes / 2
  /// 逐帧的 pts/enqueue/frame 三连日志每 60 帧采样一次；异常日志不降频。
  private static let frameSampleEvery = 60
  private static var fileURL: URL? = {
    guard
      let dir = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask
      ).first
    else { return nil }
    return dir.appendingPathComponent("pip_trace.log")
  }()

  /// 以下状态只在 `queue` 上读写：常驻句柄避免每行 open/close。
  private static var handle: FileHandle?
  /// 当前文件字节数；-1 表示尚未探测。
  private static var fileBytes = -1

  /// 逐帧日志采样计数。`process` 在 frameQueue 上调用，单独加锁。
  private static let sampleLock = NSLock()
  private static var frameCount = 0

  /// 每帧调用一次，决定这一帧是否写逐帧日志（首帧与每 60 帧一次）。
  static func shouldLogFrame() -> Bool {
    sampleLock.lock()
    defer { sampleLock.unlock() }
    frameCount &+= 1
    return frameCount == 1 || frameCount % frameSampleEvery == 0
  }

  static func log(_ message: String) {
    let line = "[\(Date().timeIntervalSince1970)] \(message)\n"
    queue.async {
      guard let url = fileURL, let data = line.data(using: .utf8) else { return }
      writeLocked(data, url: url)
    }
  }

  /// 只在 `queue` 上调用：追加一行，必要时滚动截断。
  private static func writeLocked(_ data: Data, url: URL) {
    // 句柄打不开时直接丢这一行：绝不能退回 `data.write(to:)`，那会把
    // 已有日志整文件覆盖掉。日志允许丢行，但不允许毁证据。
    guard let fileHandle = openHandle(url) else { return }
    do {
      // 常驻句柄的写位置停在上次结尾；显式 seek 到末尾保证只追加，
      // 否则句柄位置不对会覆盖已有日志。
      _ = try fileHandle.seekToEnd()
      try fileHandle.write(contentsOf: data)
      fileBytes += data.count
      if fileBytes > maxBytes {
        fileBytes = rotate(url: url, handle: fileHandle)
      }
    } catch {
      // 句柄失效（例如文件被外部删掉）：丢弃缓存，下次重开。
      try? fileHandle.close()
      handle = nil
      fileBytes = -1
    }
  }

  /// 只在 `queue` 上调用。
  private static func openHandle(_ url: URL) -> FileHandle? {
    if let existing = handle { return existing }
    if !FileManager.default.fileExists(atPath: url.path) {
      _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
    if fileBytes < 0 {
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      fileBytes = (attributes?[.size] as? Int) ?? 0
    }
    handle = opened
    return opened
  }

  /// 超过上限时截断为末尾约一半，并丢掉第一行残片保证整行完整。
  /// 只在 `queue` 上调用，返回截断后的字节数。
  private static func rotate(url: URL, handle: FileHandle) -> Int {
    try? handle.close()
    PipTrace.handle = nil
    // 只读末尾一半：升级用户可能已有上百 MB 的旧日志，整文件读入会
    // 在后台瞬间申请同等内存。失败返回 -1（未知），下一次写重新 stat。
    guard let reader = try? FileHandle(forReadingFrom: url) else { return -1 }
    defer { try? reader.close() }
    guard let size = try? reader.seekToEnd() else { return -1 }
    let keep = UInt64(keepBytes)
    guard size > keep else { return Int(size) }
    let tailData: Data?
    do {
      try reader.seek(toOffset: size - keep)
      tailData = try reader.read(upToCount: keepBytes)
    } catch {
      return -1
    }
    guard let tailData else { return -1 }
    var tail = tailData[...]
    if let newline = tail.firstIndex(of: 0x0A) {
      let afterNewline = tail.index(after: newline)
      if afterNewline < tail.endIndex {
        tail = tail[afterNewline...]
      }
    }
    let trimmed = Data(tail)
    do {
      try trimmed.write(to: url, options: .atomic)
    } catch {
      return -1
    }
    return trimmed.count
  }
}

@available(iOS 15.0, *)
private final class PipSession: NSObject {
  /// Upper bound of the longest side of the frames sent to PiP.
  private static let maxDimension = 1920.0
  /// 预热节流间隔：只用于「已 arm / 已请求启动，但 PiP 还没真正显示」的阶段。
  /// 一旦进入 PiP 就完全不节流，只保留 latest-wins 的在途帧合并。
  private static let idleFrameInterval = 0.5

  /// How long a held surface may wait for the new texture's first frame before
  /// the presentation is paused. The PiP window is never torn down here.
  private static let holdTimeout: TimeInterval = 8
  /// Retry cadence for a hold that still has no frame after a timeout.
  private static let holdRetryInterval: TimeInterval = 4
  /// Bounded retries before the terminal stalled state is logged.
  private static let maxHoldRetries = 4

  /// Retargetable: a player rebuild registers a new Flutter texture while the
  /// PiP window must stay alive on the old one until the new source shows.
  private(set) var textureId: Int64
  var onStop: (() -> Void)?
  private(set) var isActive = false
  /// dispose() arrived while the PiP surface was still visible. The controller
  /// is kept until DidStop, otherwise the window disappears and only audio
  /// keeps playing.
  private(set) var pendingTeardown = false
  /// The surface is being held on the last frame while a new texture is
  /// expected. While this is set the layer/controller must never be torn down.
  private var surfaceHoldStorage = false
  private let surfaceLock = NSLock()
  private var surfaceEpoch = 0
  private var holdAutoPaused = false
  private var holdRetryCount = 0
  /// Main thread: whether the last successfully enqueued frame is still on
  /// screen (diagnostics + hold bookkeeping).
  private var hasRetainedSurfaceFrame = false

  var autoEnter = false {
    didSet { updateAutoEnter() }
  }

  /// Keep the session alive while armed for auto-enter; a deferred dispose
  /// additionally needs the session to survive until PiP actually stops.
  var shouldTeardownOnStop: Bool { !autoEnter || pendingTeardown }

  /// Do not tear the session down while a PiP window is actually visible.
  /// An in-flight start has no surface to lose; keeping it alive is exactly
  /// the C57 regression (window pops up after returning to the foreground).
  var shouldKeepOnDisarm: Bool {
    controller.isPictureInPictureActive
  }

  private var surfaceHeld: Bool {
    get {
      surfaceLock.lock()
      defer { surfaceLock.unlock() }
      return surfaceHoldStorage
    }
    set {
      surfaceLock.lock()
      surfaceHoldStorage = newValue
      surfaceLock.unlock()
    }
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
  /// `startPictureInPicture()` 已调用、但还没收到 DidStart/DidStop 的过渡期。
  /// 这段时间必须满帧供片，否则起小窗的动画会卡。
  private var pipStartRequested = false
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
  /// 进入 PiP 那一刻的 throttle 计数，用来在 DidStop 里证明「PiP 期间零节流」。
  private var throttleDropsAtEnter = 0
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
  /// 供帧健康度窗口：PiP 期间每 5s 一条 `pip-frame-health`。
  /// 独立 Timer 保证「0 fps」也能记录下来，而不是等下一次回调。
  private var healthTimer: Timer?
  private var healthWindowStart: CFTimeInterval = 0
  private var healthCallbackBaseline = 0
  private var healthCopyAttemptBaseline = 0
  private var healthCopyNilBaseline = 0
  private var healthEnqueuedBaseline = 0
  private var healthReplayedBaseline = 0
  /// 累计计数：copyPixelBuffer 尝试 / 返回 nil / hold 旧帧回放。
  /// 前两个只在主线程读写；回放计数在 frameQueue 上算完再回主线程。
  private var copyAttemptCount = 0
  private var copyNilCount = 0
  private var replayedFrameCount = 0
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
  /// Last frame that made it into the layer. Its pixel buffer belongs to our
  /// own pool, so it can be re-enqueued while a retarget is waiting for the
  /// new texture's first frame.
  private var lastSurfacePixelBuffer: CVPixelBuffer?
  /// Set once any frame has been enqueued since the current hold started.
  private var replayBlocked = false
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
  /// 上一次输出指纹判定；nil 表示还没判过，用于只在 true/false 翻转时补日志。
  private var lastOutputChanged: Bool?
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
          // Dart 可能已在 inactive 阶段请求过；这里再推一次，确保
          // 「后台才变 possible」的机型也能真正起小窗。
          self?.startIfPending()
        }
      },
      NotificationCenter.default.addObserver(
        forName: UIScene.didActivateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        // 用户已经回到前台，上次后台请求还没落定就作废；否则稍后
        // isPictureInPicturePossible 回调会把小窗补弹出来。
        if UIApplication.shared.applicationState == .active,
          self.pendingStart, !self.isActive
        {
          self.pendingStart = false
          self.backgroundOnStart = false
          PipTrace.log("didActivate: dropped pending start")
        }
        guard self.enteredBackground else { return }
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
      logSurface("attach-miss", reason: "no-window")
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
    logSurface("attach", reason: "configure")
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
    if let value = args["isPlaying"] as? Bool {
      // While a hold timed out the presentation is paused on purpose; a Dart
      // position tick must not silently unpause it. A real pause clears the
      // auto-pause so the hold end will not resume playback later.
      if !(surfaceHeld && holdAutoPaused) {
        isPlaying = value
      }
      if !value {
        holdAutoPaused = false
      }
    }
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
    beginStart(backgroundOnStart: true)
  }

  /// 显式请求启动画中画，但不再主动把 App 推到后台（用户已经按了 Home）。
  func requestStart() {
    beginStart(backgroundOnStart: false)
  }

  private func beginStart(backgroundOnStart: Bool) {
    guard !controller.isPictureInPictureActive else { return }
    if pipStartRequested {
      PipTrace.log("requestStart: ignored, start already in flight")
      return
    }
    // 同一个退后台过程里 inactive / hidden / paused 会连续触发；只认第一次，
    // 但允许在上一次 2s 兜底放弃后重试。
    if pendingStart {
      PipTrace.log("requestStart: ignored, already pending")
      return
    }
    pendingStart = true
    self.backgroundOnStart = backgroundOnStart
    startFrameHealthTimer()
    PipTrace.log(
      "requestStart: hasFrame=\(hasFrame) autoEnter=\(autoEnter) "
        + "appState=\(UIApplication.shared.applicationState.rawValue) "
        + "possible=\(controller.isPictureInPicturePossible)"
    )
    startIfPending()
    // Give up if PiP doesn't become possible shortly, so a stale request
    // doesn't start PiP unexpectedly later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self else { return }
      if self.pendingStart {
        self.pendingStart = false
        self.backgroundOnStart = false
        self.stopFrameHealthTimer(emitSnapshot: true)
        self.sendEvent("onStateChanged", ["active": false, "error": "PiP is not possible"])
        self.onStop?()
        return
      }
      // AVKit 既不回调 DidStart 也不回调 failedToStart 时，过渡标记会一直
      // 挂着并挡住后续手动/自动请求；这里只清标记，不碰已激活的小窗。
      if self.pipStartRequested && !self.isActive
        && !self.controller.isPictureInPictureActive
      {
        self.pipStartRequested = false
        PipTrace.log("requestStart: cleared stale pipStartRequested")
      }
      PipTrace.log(
        "requestStart: after 2s active=\(self.isActive) "
          + "pipActive=\(self.controller.isPictureInPictureActive)"
      )
    }
  }

  private func startIfPending() {
    PipTrace.log(
      "startIfPending: pending=\(pendingStart) hasFrame=\(hasFrame) "
        + "possible=\(controller.isPictureInPicturePossible)"
    )
    guard pendingStart, hasFrame, controller.isPictureInPicturePossible else { return }
    pendingStart = false
    pipStartRequested = true
    controller.startPictureInPicture()
  }

  private func updateAutoEnter() {
    // AVKit may start PiP as soon as the app goes to background.
    controller.canStartPictureInPictureAutomaticallyFromInline = autoEnter && hasFrame
  }

  // MARK: Surface continuity

  /// A texture switch must never destroy the PiP surface. Retarget reuses the
  /// exact same controller/layer/view, keeps the last frame visible and only
  /// swaps the id that frames are pulled from.
  func retarget(to newTextureId: Int64, reason: String) {
    let previous = textureId
    guard previous != newTextureId else { return }
    if needsSurfaceHold {
      beginSurfaceHold(reason: "retarget")
    }
    textureId = newTextureId
    // The new texture has not delivered a frame yet. Without this reset both
    // startIfPending() and the background auto-enter path would keep acting on
    // the old texture's "has a frame" state and start PiP on an empty surface.
    // The sameTexture completion branch flips it back once the new source
    // enqueues its first frame.
    hasFrame = false
    updateAutoEnter()
    pendingTeardown = false
    pendingFrameRequested = false
    // New source => new decoder/pixel format. Drop the cached format and
    // pools on the frame queue; makeSampleBuffer recreates them.
    frameQueue.async { [weak self] in
      guard let self else { return }
      self.formatDescription = nil
      self.pool = nil
      self.poolSize = .zero
      self.directPool = nil
      self.directPoolSize = .zero
      self.directPoolFormat = 0
      self.replayBlocked = false
    }
    PipTrace.log(
      "retarget: \(previous) -> \(newTextureId) reason=\(reason) "
        + "pipActive=\(controller.isPictureInPictureActive) hold=\(surfaceHeld)"
    )
    logSurface("retarget", reason: reason)
    frameAvailable(force: true)
  }

  /// Called when the engine unregisters a texture. If it was the current PiP
  /// source, hold the last frame instead of letting the surface go empty.
  func surfaceSourceUnregistered() {
    guard needsSurfaceHold else { return }
    beginSurfaceHold(reason: "texture-unregistered")
  }

  /// PiP 窗口正在显示，或 surface 正 hold 着最后一帧：此时源纹理一旦换新，
  /// 必须跟着 retarget，否则 session 会一直停在已 unregister 的旧 id 上，
  /// 窗口只剩 hold 的最后一帧（有声无画）。
  var pipActiveOrHolding: Bool {
    controller.isPictureInPictureActive || surfaceHeld
  }

  private var needsSurfaceHold: Bool {
    isActive || controller.isPictureInPictureActive || pipStartRequested
      || (autoEnter && UIApplication.shared.applicationState != .active)
  }

  /// Entered again with the same texture: frames should already flow; release
  /// any hold and auto-resume playback if the hold had paused it.
  func releaseSurfaceHold(reason: String) {
    // An explicit enter for the current texture means the surface is wanted,
    // but only if the engine still owns that id. A dead id must not clear the
    // deferred teardown: there would be no source left behind the window.
    guard TextureTracker.texture(for: textureId) != nil else {
      surfaceSourceUnregistered()
      return
    }
    pendingTeardown = false
    endSurfaceHold(reason: reason)
  }

  /// Dispose of the controller only when no PiP surface would disappear.
  func deferTeardownForDispose() -> Bool {
    // A rebuild that replaces the player (auto-recover / proactive) tears the
    // controller down and leaves PiP with audio but no pixels. Leaving the
    // video page also disposes the player, but Dart calls disableAutoEnter
    // first on that path, so the two are distinguishable: no surface means
    // nothing to lose, and an already-disarmed session in the foreground is a
    // deliberate page exit that must still close the window.
    guard isActive || controller.isPictureInPictureActive else { return false }
    let background = UIApplication.shared.applicationState != .active
    guard background || autoEnter else { return false }
    pendingTeardown = true
    PipTrace.log(
      "dispose: deferred pendingTeardown=YES "
        + "pipActive=\(controller.isPictureInPictureActive) hold=\(surfaceHeld) "
        + "background=\(background) autoEnter=\(autoEnter)"
    )
    logSurface("dispose-deferred", reason: "pip-active")
    return true
  }

  /// C57 regression guard: disarm may arrive while a start is still pending.
  /// Drop that pending start, but never touch an already visible window.
  func noteAutoEnterDisabled() {
    guard !isActive, !controller.isPictureInPictureActive else { return }
    if pendingStart {
      PipTrace.log("disableAutoEnter: dropped pending start")
    }
    if pipStartRequested {
      // startPictureInPicture() is in flight but there is no visible surface
      // yet. Cancel it, otherwise AVKit can still pop the window after the app
      // is back in the foreground (C57).
      PipTrace.log("disableAutoEnter: cancelling in-flight start")
      stopRequested = true
      controller.stopPictureInPicture()
      pipStartRequested = false
    }
    pendingStart = false
    backgroundOnStart = false
  }

  private func beginSurfaceHold(reason: String) {
    guard !surfaceHeld else { return }
    surfaceHeld = true
    holdRetryCount = 0
    surfaceEpoch &+= 1
    let token = surfaceEpoch
    // Allow the retained frame to be replayed until the new source lands one.
    frameQueue.async { [weak self] in
      self?.replayBlocked = false
    }
    PipTrace.log(
      "pip-surface: hold start texture=\(textureId) reason=\(reason) "
        + "pipActive=\(controller.isPictureInPictureActive)"
    )
    logSurface("hold-start", reason: reason)
    scheduleHoldTick(token: token)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdTimeout) { [weak self] in
      guard let self, self.surfaceEpoch == token, self.surfaceHeld else { return }
      self.pauseForHoldTimeout(reason: reason)
    }
  }

  /// Ends a hold and resumes playback when the hold auto-paused it.
  private func endSurfaceHold(reason: String) {
    guard surfaceHeld else { return }
    let wasAutoPaused = holdAutoPaused
    surfaceHeld = false
    surfaceEpoch &+= 1
    logSurface("hold-end", reason: reason)
    if wasAutoPaused {
      holdAutoPaused = false
      resumePlaybackAfterHold(reason: reason)
    }
  }

  /// Ends a hold without resuming (PiP stopped / session is going away).
  private func cancelSurfaceHold(reason: String) {
    guard surfaceHeld else { return }
    surfaceHeld = false
    holdAutoPaused = false
    surfaceEpoch &+= 1
    logSurface("hold-cancel", reason: reason)
  }

  /// Re-enqueue the retained frame every second while holding so the display
  /// layer never runs dry during a slow rebuild. Skips once any frame landed
  /// after the hold began (replayBlocked is frame-queue confined).
  private func scheduleHoldTick(token: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self, self.surfaceEpoch == token, self.surfaceHeld else { return }
      // Capture on main; textureId may be retargeted while this runs.
      let sourceTextureId = self.textureId
      self.frameQueue.async { [weak self] in
        guard let self, !self.replayBlocked else { return }
        self.replayHeldFrame(textureId: sourceTextureId)
      }
      self.scheduleHoldTick(token: token)
    }
  }

  /// Must run on frameQueue.
  private func replayHeldFrame(textureId: Int64) {
    guard let pixelBuffer = lastSurfacePixelBuffer else { return }
    var stage = "hold-replay"
    guard
      let sampleBuffer = makeSampleBuffer(
        pixelBuffer,
        stage: &stage,
        verbose: false
      ),
      enqueue(sampleBuffer, stage: &stage, verbose: false)
    else { return }
    PipTrace.log(
      "pip-surface: replayed held frame texture=\(textureId) size="
        + "\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))"
    )
    DispatchQueue.main.async { [weak self] in
      self?.replayedFrameCount += 1
    }
  }

  /// Fallback B: if a rebuild really is needed and takes too long, pause the
  /// PiP presentation instead of leaving a live window with no fresh pixels.
  /// The media keeps decoding so the new texture can still deliver its first
  /// frame; the window resumes as soon as that frame lands.
  private func pauseForHoldTimeout(reason: String) {
    guard surfaceHeld else { return }
    holdRetryCount += 1
    let hasSource = TextureTracker.texture(for: textureId) != nil
    logSurface(
      "hold-timeout",
      reason: "\(reason) attempt=\(holdRetryCount) source=\(hasSource ? "YES" : "NO")"
    )
    if hasSource {
      // The new texture may have registered without ever delivering a frame
      // callback. Pull from it again before parking the presentation.
      seekGeneration &+= 1
      requestFramesAfterReset(generation: seekGeneration)
    } else {
      // The engine already dropped this id; there is nothing to pull until a
      // new texture registers, so keep the last frame visible and retry.
      logSurface("source-gone", reason: "hold-timeout")
    }
    if isPlaying {
      holdAutoPaused = true
      isPlaying = false
      let status = CMTimebaseSetRate(timebase, rate: 0)
      controller.invalidatePlaybackState()
      PipTrace.log(
        "pip-surface: paused presentation after hold timeout reason=\(reason) "
          + "status=\(status)"
      )
    }
    guard holdRetryCount < Self.maxHoldRetries else {
      // Terminal, bounded state: keep the last frame in the layer instead of
      // invalidating the controller. Audio is untouched, and the user can
      // resume manually if the source comes back.
      surfaceHeld = false
      holdAutoPaused = false
      surfaceEpoch &+= 1
      logSurface("hold-stalled", reason: "no-frame-after-\(holdRetryCount)-attempts")
      return
    }
    let token = surfaceEpoch
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdRetryInterval) { [weak self] in
      guard let self, self.surfaceEpoch == token, self.surfaceHeld else { return }
      self.pauseForHoldTimeout(reason: reason)
    }
  }

  private func resumePlaybackAfterHold(reason: String) {
    guard !surfaceHeld else { return }
    isPlaying = true
    resetTimebase(targetMs: max(0, positionMs), reason: "hold-resume")
    controller.invalidatePlaybackState()
    sendEvent("setPlaying", true)
    seekGeneration &+= 1
    requestFramesAfterReset(generation: seekGeneration)
    logSurface("hold-resume", reason: reason)
  }

  /// Diagnostics for the 15PM "PiP window has no pixels" case. Must run on
  /// the main thread because it reads the layer/view geometry.
  private func logSurface(_ event: String, reason: String) {
    let layerSize = displayLayer.bounds.size
    var ready = displayLayer.isReadyForMoreMediaData
    var rendererStatus = "n/a"
    if #available(iOS 17.0, *) {
      ready = displayLayer.sampleBufferRenderer.isReadyForMoreMediaData
      rendererStatus = "\(displayLayer.sampleBufferRenderer.status.rawValue)"
    }
    let layerError = displayLayer.error.map { "\($0)" } ?? "nil"
    PipTrace.log(
      "pip-surface: event=\(event) texture=\(textureId) "
        + "layer=\(Int(layerSize.width))x\(Int(layerSize.height)) "
        + "view=\(Int(sourceView.bounds.width))x\(Int(sourceView.bounds.height)) "
        + "attached=\(displayLayer.superlayer != nil ? "YES" : "NO") "
        + "inWindow=\(sourceView.superview != nil ? "YES" : "NO") "
        + "hasPixelBuffer=\(hasRetainedSurfaceFrame ? "YES" : "NO") "
        + "hasPixelBufferSemantics=last-enqueued "
        + "layerStatus=\(displayLayer.status.rawValue) rendererStatus=\(rendererStatus) "
        + "ready=\(ready) layerError=\(layerError) "
        + "ios=\(UIDevice.current.systemVersion) "
        + "pipActive=\(controller.isPictureInPictureActive ? "YES" : "NO") "
        + "hold=\(surfaceHeld ? "YES" : "NO") reason=\(reason)"
    )
  }

  func invalidate() {
    stopFrameHealthTimer(emitSnapshot: true)
    logSurface("detach", reason: "invalidate")
    cancelSurfaceHold(reason: "invalidate")
    pendingStart = false
    pipStartRequested = false
    pendingFrameRequested = false
    backgroundOnStart = false
    pendingTeardown = false
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
    hasRetainedSurfaceFrame = false
    // The content source retains its playback delegate (`self`).
    controller.contentSource = nil
    sourceView.removeFromSuperview()
    PipTrace.log(
      "summary: isActive=\(isActive) textureCallbacks=\(textureCallbackCount) "
        + "frameInFlightDrops=\(frameInFlightDropCount) "
        + "throttleDrops=\(throttleDropCount) enqueued=\(enqueuedFrameCount) "
        + "shown=\(shownFrameCount) droppedOld=\(droppedOldFrameCount) "
        + "direct=\(directFrameCount) render=\(renderFrameCount) "
        + "copyAttempts=\(copyAttemptCount) copyNil=\(copyNilCount) "
        + "replayed=\(replayedFrameCount) "
        + "idleMs=\(Int(Self.idleFrameInterval * 1000))"
    )
    // 同步在 frameQueue 上取快照：tearDown() 随后会把 session 置空，
    // 异步闭包可能已经拿不到统计值。
    frameQueue.sync { writeVerdictIfNeeded() }
  }

  // MARK: Frame health

  /// 开始 PiP 供帧健康度采样。重复调用只保留第一个窗口。
  private func startFrameHealthTimer() {
    guard healthTimer == nil else { return }
    let now = CACurrentMediaTime()
    healthWindowStart = now
    healthCallbackBaseline = textureCallbackCount
    healthCopyAttemptBaseline = copyAttemptCount
    healthCopyNilBaseline = copyNilCount
    healthEnqueuedBaseline = enqueuedFrameCount
    healthReplayedBaseline = replayedFrameCount
    healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
      [weak self] _ in
      self?.logFrameHealth()
    }
    PipTrace.log(
      "pip-frame-health: timer start texture=\(textureId) "
        + "callbacks=\(textureCallbackCount)"
    )
  }

  /// 停止采样；`emitSnapshot` 为真时先把当前窗口落一行，便于对照起止。
  private func stopFrameHealthTimer(emitSnapshot: Bool = false) {
    if emitSnapshot { logFrameHealth() }
    healthTimer?.invalidate()
    healthTimer = nil
    healthWindowStart = 0
  }

  /// 输出最近一个窗口的帧率与两类「假帧」占比。
  ///
  /// - frameAvailablePerSec：原生收到多少次 `textureFrameAvailable`；
  /// - copyPixelBufferNilRatio：取帧尝试中拿到 nil 的比例；
  /// - replayedFrameRatio：喂给小窗的帧里 hold 旧帧回放占多少。
  private func logFrameHealth() {
    guard healthWindowStart > 0 else { return }
    let now = CACurrentMediaTime()
    let elapsed = max(0.001, now - healthWindowStart)
    let callbacks = textureCallbackCount - healthCallbackBaseline
    let attempts = copyAttemptCount - healthCopyAttemptBaseline
    let nils = copyNilCount - healthCopyNilBaseline
    let fresh = enqueuedFrameCount - healthEnqueuedBaseline
    let replays = replayedFrameCount - healthReplayedBaseline
    let fps = Double(callbacks) / elapsed
    let nilRatio = attempts > 0 ? Double(nils) / Double(attempts) : 0
    let fed = fresh + replays
    let replayRatio = fed > 0 ? Double(replays) / Double(fed) : 0
    PipTrace.log(
      "pip-frame-health: frameAvailablePerSec="
        + String(format: "%.1f", fps)
        + " copyPixelBufferNilRatio="
        + String(format: "%.2f", nilRatio)
        + " replayedFrameRatio="
        + String(format: "%.2f", replayRatio)
        + " callbacks=\(callbacks) copyAttempts=\(attempts) copyNil=\(nils) "
        + "freshEnqueued=\(fresh) replayed=\(replays) "
        + "droppedOld=\(droppedOldFrameCount) enqueuedTotal=\(enqueuedFrameCount) "
        + "hold=\(surfaceHeld ? "YES" : "NO") "
        + "pipActive=\(controller.isPictureInPictureActive ? "YES" : "NO")"
    )
    healthWindowStart = now
    healthCallbackBaseline = textureCallbackCount
    healthCopyAttemptBaseline = copyAttemptCount
    healthCopyNilBaseline = copyNilCount
    healthEnqueuedBaseline = enqueuedFrameCount
    healthReplayedBaseline = replayedFrameCount
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
    if !force && shouldThrottleForIdle(now: now) {
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
    copyAttemptCount += 1
    guard let source = texture.copyPixelBuffer()?.takeRetainedValue() else {
      copyNilCount += 1
      PipTrace.log("frameAvailable: copyPixelBuffer returned nil for id=\(textureId)")
      return
    }
    process(source)
  }

  /// 只有「还没进 PiP 的预热阶段」才限速。
  ///
  /// 不能只看自己的 `isActive`：自动进入画中画时 delegate 回调可能滞后，
  /// 甚至整段丢失，一旦漏置位就会把整个 PiP 期间都按 idle 节流（实测
  /// throttleDrops 占到 87%）。所以这里同时采信 AVKit 的
  /// `isPictureInPictureActive`，任一为真都视为已经在出小窗。
  private func shouldThrottleForIdle(now: CFTimeInterval) -> Bool {
    if isActive || controller.isPictureInPictureActive { return false }
    // 正在启动 / 已 arm 且 App 已退后台：PiP 马上要显示，这一段不能降到
    // 2fps，否则起小窗的动画和首帧都会明显卡。
    if pendingStart || pipStartRequested { return false }
    if autoEnter && UIApplication.shared.applicationState != .active {
      return false
    }
    return now - lastFrameTime < Self.idleFrameInterval
  }

  /// Runs one frame on `frameQueue`. Must be called on the main thread.
  private func process(_ source: CVPixelBuffer) {
    frameInFlight = true
    frameInFlightSince = CACurrentMediaTime()
    frameGeneration &+= 1
    let generation = frameGeneration
    // Captured on main: if a retarget happens while this frame is in flight,
    // its content belongs to the previous texture and must not end the hold.
    let sourceTextureId = textureId
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
      // 逐帧三连日志每 60 帧采样一次；异常日志（copy-slow / 失败分支）不降频。
      let verbose = PipTrace.shouldLogFrame()
      let sourceFormat = CVPixelBufferGetPixelFormatType(source)
      self.recordSourceFingerprint(source, active: active)
      let pixelBuffer: CVPixelBuffer?
      if Self.isDisplayableFormat(sourceFormat),
        let directCopy = self.copyDirect(source, stage: &stage, verbose: verbose)
      {
        pixelBuffer = directCopy
        direct = true
      } else {
        pixelBuffer = self.copy(
          source,
          fallbackRenderSize: fallbackRenderSize,
          stage: &stage,
          verbose: verbose
        )
      }
      if verbose {
        PipTrace.log(
          "direct-enqueue: pixfmt=\(Self.pixelFormatName(sourceFormat)) "
            + "skipRender=\(direct ? "YES" : "NO") "
            + "src=\(CVPixelBufferGetWidth(source))x\(CVPixelBufferGetHeight(source))"
        )
      }
      if let pixelBuffer,
        let sampleBuffer = self.makeSampleBuffer(
          pixelBuffer,
          stage: &stage,
          verbose: verbose
        )
      {
        enqueued = self.enqueue(sampleBuffer, stage: &stage, verbose: verbose)
        if enqueued {
          // Own pool buffer, safe to keep and replay while retargeting.
          self.lastSurfacePixelBuffer = pixelBuffer
          self.replayBlocked = true
        }
      }
      let layerStatus = self.displayLayer.status.rawValue
      let ready = self.displayLayer.isReadyForMoreMediaData
      if verbose {
        PipTrace.log(
          "frame: enqueued=\(enqueued) stage=\(stage) direct=\(direct ? "YES" : "NO") "
            + "layerStatus=\(layerStatus) "
            + "ready=\(ready) size=\(CVPixelBufferGetWidth(source))x"
            + "\(CVPixelBufferGetHeight(source))"
        )
      }
      DispatchQueue.main.async {
        guard self.frameGeneration == generation else {
          // A newer generation already owns frameInFlight (watchdog or a new
          // texture). Touching it here would let two frames render at once,
          // so just drop this stale completion.
          return
        }
        let sameTexture = self.textureId == sourceTextureId
        self.frameInFlight = false
        if enqueued {
          self.enqueuedFrameCount += 1
          self.shownFrameCount += 1
          self.hasRetainedSurfaceFrame = true
        }
        if direct {
          self.directFrameCount += 1
        } else {
          self.renderFrameCount += 1
        }
        if enqueued && sameTexture && !self.hasFrame {
          self.hasFrame = true
          self.updateAutoEnter()
          self.startIfPending()
        }
        if enqueued && sameTexture {
          self.endSurfaceHold(reason: "first-frame")
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
    guard let texture = TextureTracker.texture(for: textureId) else {
      return
    }
    copyAttemptCount += 1
    guard let source = texture.copyPixelBuffer()?.takeRetainedValue() else {
      copyNilCount += 1
      return
    }
    process(source)
  }

  private func copy(
    _ source: CVPixelBuffer,
    fallbackRenderSize: CGSize,
    stage: inout String,
    verbose: Bool
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
      if verbose {
        PipTrace.log("copy-timing: \(details)")
      }
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
    recordOutputFingerprint(output, verbose: verbose)
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
    stage: inout String,
    verbose: Bool
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
    if verbose {
      PipTrace.log("copy-timing: direct \(details)")
    }
    if totalMs > 30 {
      PipTrace.log("copy-slow: stage=direct-copy ms=\(totalMs) \(details)")
    }
    recordOutputFingerprint(output, verbose: verbose)
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

  /// 对 render 后的 output 算指纹。采样帧写 true/false，直接对应
  /// 「这一帧和上一帧的渲染结果是否不同」；非采样帧只在 changed=false
  /// （疑似卡住）时补一条，保证异常证据不丢。
  private func recordOutputFingerprint(
    _ output: CVPixelBuffer,
    verbose: Bool
  ) {
    guard let hash = pixelFingerprint(output) else {
      if verbose {
        PipTrace.log("out-hash-changed: false (lock failed)")
      }
      return
    }
    let changed = !hasOutputHash || hash != lastOutputHash
    hasOutputHash = true
    lastOutputHash = hash
    // 采样帧记录 true/false；非采样帧只在状态翻转时补一条。冻结期间每帧
    // 都写 false 会重新制造大量噪声，异常持续性由 stale-source 留证。
    let flipped = lastOutputChanged != changed
    lastOutputChanged = changed
    if verbose || flipped {
      PipTrace.log("out-hash-changed: \(changed)")
    }
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
    stage: inout String,
    verbose: Bool
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
    if verbose {
      PipTrace.log(
        "pts: value=\(pts.seconds) timebase=\(now.seconds) deltaMs=\(deltaMs)"
      )
    }

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

  private func enqueue(
    _ sampleBuffer: CMSampleBuffer,
    stage: inout String,
    verbose: Bool
  ) -> Bool {
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
      if verbose {
        PipTrace.log(
          "enqueue(before): isReadyForMoreMediaData="
            + "\(renderer.isReadyForMoreMediaData) status=\(renderer.status.rawValue) "
            + "layerStatus=\(displayLayer.status.rawValue) "
            + "requiresFlush=\(renderer.requiresFlushToResumeDecoding) "
            + "pts=\(pts.seconds) ptsAgeMs=\(ptsAgeMs)"
        )
      }
      if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
        renderer.flush()
      }
      renderer.enqueue(sampleBuffer)
      enqueued = renderer.status != .failed
      let elapsedMs = Int((CACurrentMediaTime() - began) * 1000)
      if verbose || !enqueued || elapsedMs > 30 {
        PipTrace.log(
          "enqueue(after): isReadyForMoreMediaData="
            + "\(renderer.isReadyForMoreMediaData) status=\(renderer.status.rawValue) "
            + "layerStatus=\(displayLayer.status.rawValue) enqueued=\(enqueued) "
            + "elapsedMs=\(elapsedMs)"
        )
      }
    } else {
      if verbose {
        PipTrace.log(
          "enqueue(before): isReadyForMoreMediaData="
            + "\(displayLayer.isReadyForMoreMediaData) "
            + "status=\(displayLayer.status.rawValue) "
            + "requiresFlush=\(displayLayer.requiresFlushToResumeDecoding) "
            + "pts=\(pts.seconds) ptsAgeMs=\(ptsAgeMs)"
        )
      }
      if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
        displayLayer.flush()
      }
      displayLayer.enqueue(sampleBuffer)
      enqueued = displayLayer.status != .failed
      let elapsedMs = Int((CACurrentMediaTime() - began) * 1000)
      if verbose || !enqueued || elapsedMs > 30 {
        PipTrace.log(
          "enqueue(after): isReadyForMoreMediaData="
            + "\(displayLayer.isReadyForMoreMediaData) "
            + "status=\(displayLayer.status.rawValue) enqueued=\(enqueued) "
            + "elapsedMs=\(elapsedMs)"
        )
      }
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
    pipStartRequested = false
    throttleDropsAtEnter = throttleDropCount
    stopRequested = false
    restoring = false
    startFrameHealthTimer()
    PipTrace.log(
      "WILL start: isActive=\(isActive) sourceViewInTree=\(sourceView.superview != nil) "
        + "throttleDrops=\(throttleDropCount)"
    )
    frameAvailable(force: true)
    sendEvent("onStateChanged", ["active": true])
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // DidStart 是「小窗真的显示了」的唯一可靠信号。delegate 顺序理论上
    // WillStart 在前，但自动进入时可能只收到 DidStart，这里再置一次，
    // 保证此后 frameAvailable 不再走 idle 节流。
    isActive = true
    pipStartRequested = false
    startFrameHealthTimer()
    // WillStart 可能在自动进入时被整段跳过，这里再取一次基线，
    // 否则 DidStop 的 throttleDropsDuringPip 会把预热期的丢帧也算进来。
    throttleDropsAtEnter = throttleDropCount
    PipTrace.log(
      "DID start: isActive=\(isActive) layerInTree=\(displayLayer.superlayer != nil) "
        + "hasFrame=\(hasFrame) idleMs=\(Int(Self.idleFrameInterval * 1000))"
    )
    logSurface("pip-did-start", reason: "delegate")
    sendEvent("onStateChanged", ["active": true])
    frameAvailable(force: true)
    if !autoEnter && !backgroundOnStart
      && UIApplication.shared.applicationState == .active
      && !stopRequested
    {
      // The start was requested from Home but landed after returning to the
      // foreground with auto-enter already disarmed (C57). Close it instead of
      // popping a PiP window over the app.
      PipTrace.log("DID start: autoEnter=NO foreground -> stop")
      stopRequested = true
      controller.stopPictureInPicture()
    }
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
    pipStartRequested = false
    backgroundOnStart = false
    stopFrameHealthTimer(emitSnapshot: true)
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
    let throttledDuringPip = throttleDropCount - throttleDropsAtEnter
    isActive = false
    pipStartRequested = false
    stopFrameHealthTimer(emitSnapshot: true)
    cancelSurfaceHold(reason: "pip-stopped")
    // Neither restored nor stopped by the app: closed from the PiP window.
    let closed = !restoring && !stopRequested
    PipTrace.log(
      "DID stop: isActive=\(isActive) closed=\(closed) restoring=\(restoring) "
        + "stopRequested=\(stopRequested) "
        + "throttleDropsDuringPip=\(throttledDuringPip) "
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
    if !playing {
      // A user pause must not be undone by a hold auto-resume.
      holdAutoPaused = false
    }
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
  static var onTextureUnregistered: ((Int64) -> Void)?
  /// 新纹理注册回调。播放器重建拿到新 textureId 后靠它把 PiP 源接过去。
  static var onTextureRegistered: ((Int64) -> Void)?

  static func texture(for textureId: Int64) -> FlutterTexture? {
    textures[textureId]?.value
  }

  static func install(on registry: FlutterTextureRegistry) {
    guard !installed, let cls = object_getClass(registry) else { return }
    installed = true

    let registerSelector = NSSelectorFromString("registerTexture:")
    let registerHooked = hook(cls, registerSelector) { original in
      typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Int64
      let function = unsafeBitCast(original, to: Function.self)
      let block: @convention(block) (AnyObject, AnyObject) -> Int64 = { this, texture in
        let textureId = function(this, registerSelector, texture)
        if let texture = texture as? FlutterTexture {
          Self.textures = Self.textures.filter { $0.value.value != nil }
          Self.textures[textureId] = WeakTexture(texture)
        }
        // 通知 PiP：重建后的新纹理已注册，可以把源接过去。
        Self.onTextureRegistered?(textureId)
        return textureId
      }
      return unsafeBitCast(block, to: AnyObject.self)
    }

    let frameAvailableSelector = NSSelectorFromString("textureFrameAvailable:")
    let frameHooked = hook(cls, frameAvailableSelector) { original in
      typealias Function = @convention(c) (AnyObject, Selector, Int64) -> Void
      let function = unsafeBitCast(original, to: Function.self)
      let block: @convention(block) (AnyObject, Int64) -> Void = { this, textureId in
        function(this, frameAvailableSelector, textureId)
        Self.onFrameAvailable?(textureId)
      }
      return unsafeBitCast(block, to: AnyObject.self)
    }

    let unregisterSelector = NSSelectorFromString("unregisterTexture:")
    let unregisterHooked = hook(cls, unregisterSelector) { original in
      typealias Function = @convention(c) (AnyObject, Selector, Int64) -> Void
      let function = unsafeBitCast(original, to: Function.self)
      let block: @convention(block) (AnyObject, Int64) -> Void = { this, textureId in
        // Notify before the texture goes away so the PiP layer can hold its
        // last frame instead of losing the surface.
        Self.onTextureUnregistered?(textureId)
        function(this, unregisterSelector, textureId)
        Self.textures[textureId] = nil
      }
      return unsafeBitCast(block, to: AnyObject.self)
    }

    PipTrace.log(
      "pip-surface: hooks register=\(registerHooked ? "OK" : "NO") "
        + "frame=\(frameHooked ? "OK" : "NO") "
        + "unregister=\(unregisterHooked ? "OK" : "NO")"
    )
  }

  @discardableResult
  private static func hook(
    _ cls: AnyClass,
    _ selector: Selector,
    _ makeBlock: (IMP) -> AnyObject
  ) -> Bool {
    guard let method = class_getInstanceMethod(cls, selector) else {
      NSLog("PipPlugin: \(cls) does not respond to \(selector)")
      return false
    }
    let imp = imp_implementationWithBlock(makeBlock(method_getImplementation(method)))
    // Add an override if the method is inherited, so the superclass is untouched.
    if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
      method_setImplementation(method, imp)
    }
    return true
  }
}
