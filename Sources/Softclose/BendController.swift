import AppKit
import Combine
import MetalKit

/// Ties the hinge to the screen.
///
/// Nothing runs while the lid is simply open: no capture, no render loop, no
/// window on screen. The first degree of movement past the clear angle brings
/// all three up, and the desktop clearing takes them down again.
@MainActor
final class BendController {
    private let settings: Settings
    private let sensor = LidAngleSensor()
    private let device: MTLDevice
    private let capture: ScreenCapture
    private let renderer: BendRenderer
    private var window: OverlayWindow?
    private let click = Click()

    private var isActive = false
    private var didReachBend = false
    /// When capture last refused, so a denial isn't retried every heartbeat.
    private var captureDeniedAt: Date?
    /// A pending capture shutdown, cancelled if the lid moves again first.
    private var pendingCaptureStop: DispatchWorkItem?
    /// When the hinge last read a different angle.
    private var lastAngleChange = Date()
    private var cancellables = Set<AnyCancellable>()
    private var idleTimer: Timer?

    /// Live angle for the menu bar and settings readout.
    private(set) var currentAngle: Double?
    var onAngleChange: ((Double?) -> Void)?

    var sensorIsAvailable: Bool { sensor.isAvailable }

    init(settings: Settings) throws {
        self.settings = settings
        guard let device = MTLCreateSystemDefaultDevice() else { throw ControllerError.noMetal }
        self.device = device
        self.capture = ScreenCapture(device: device)
        let capture = self.capture
        self.renderer = try BendRenderer(device: device,
                                         textureProvider: { capture.currentTexture() },
                                         settings: settings)

        renderer.progressProvider = { [weak self] in
            MainActor.assumeIsolated { self?.currentProgress() ?? 0 }
        }

        renderer.onFrame = { [weak self] progress in
            MainActor.assumeIsolated {
                self?.didRenderFrame(progress: progress)
                AppStatus.shared.publish(progress: Double(progress))
            }
        }

        sensor.onChange = { [weak self] angle in
            MainActor.assumeIsolated { self?.update(angle: angle) }
        }
    }

    func start() {
        sensor.start()
        currentAngle = settings.manualAngle ?? sensor.angle
        settings.calibrateClearAngleIfNeeded(restingAt: sensor.angle)
        Log.info("start: sensor=\(sensor.isAvailable) angle=\(currentAngle.map { String(format: "%.0f", $0) } ?? "nil") clearAngle=\(settings.clearAngle) permission=\(ScreenPermission.isGranted)")

        // The sensor polls on its own timer, so this exists only to re-check
        // state that changes without the hinge moving — Screen Recording being
        // granted, chiefly, which is not something we can subscribe to.
        //
        // It deliberately does not read the angle. Doing so would be a second
        // poll on top of the sensor's own, and passing an unchanged angle
        // through update() would refresh the "last moved" timestamp twice a
        // second, so the lid could never be seen holding still and the slow
        // watch below would never engage.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }

        // Settings changes need to be reflected even when nothing is moving.
        for publisher in [
            settings.$clearAngle.map { _ in () }.eraseToAnyPublisher(),
            settings.$isPaused.map { _ in () }.eraseToAnyPublisher(),
            settings.$manualAngle.map { _ in () }.eraseToAnyPublisher(),
        ] {
            publisher.receive(on: RunLoop.main).sink { [weak self] in
                MainActor.assumeIsolated { self?.reevaluate() }
            }.store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.screenParametersChanged() }
            }.store(in: &cancellables)

        reevaluate()
    }

    /// The lid one. An external display isn't hinged to anything.
    private var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? NSScreen.main
    }

    /// How far the fold should be right now, from the freshest angle available.
    /// Called once per frame by the renderer.
    private func currentProgress() -> Float {
        guard !settings.isPaused else { return 0 }
        if let manual = settings.manualAngle {
            return Float(BendCurve.progress(angle: manual, clearAngle: settings.clearAngle))
        }
        guard let angle = sensor.extrapolatedAngle() else { return 0 }
        return Float(BendCurve.progress(angle: angle, clearAngle: settings.clearAngle))
    }

    private func update(angle: Double) {
        lastAngleChange = Date()
        currentAngle = angle
        onAngleChange?(angle)
        reevaluate()
    }

    private func reevaluate() {
        let angle = settings.manualAngle ?? currentAngle
        if settings.manualAngle != nil {
            currentAngle = angle
            onAngleChange?(angle)
        }
        guard let angle, !settings.isPaused else {
            renderer.targetProgress = 0
            if settings.isPaused { deactivateImmediately() }
            return
        }

        let progress = Float(BendCurve.progress(angle: angle, clearAngle: settings.clearAngle))
        renderer.targetProgress = progress

        // Capture is brought up slightly before the fold is visible, because
        // starting a stream takes a moment and the effect would otherwise
        // appear a beat late and part-way down.
        //
        // Being near the clear angle is not enough on its own to justify that:
        // plenty of people work with the lid a few degrees above it, and
        // holding a capture stream open the whole time would mean recording the
        // screen during ordinary use. So the lid also has to be *moving
        // closed*. Sitting still inside the band captures nothing.
        let nearClearAngle = angle < settings.clearAngle + Self.preRollDegrees
        let closing = sensor.velocity < -Self.closingDegreesPerSecond
        let approaching = nearClearAngle && (closing || progress > 0.001)

        // Polling costs about half a millisecond of blocking IPC per read — the
        // cheap element read turns out to be a stale mirror of the sensor's 1 Hz
        // push, so there is no way around paying for it. The rate therefore
        // follows how likely the next read is to tell us anything.
        //
        // A lid that hasn't moved in seconds is the common case by far: someone
        // working with the laptop open. Polling it fifteen times a second to
        // re-read a number that isn't changing is the single largest thing this
        // app does while doing nothing. It drops to a slow watch, and any
        // change at all takes it straight back up.
        let stillFor = Date().timeIntervalSince(lastAngleChange)
        let rate: Double
        if approaching || progress > 0.001 {
            rate = LidAngleSensor.activeRate
        } else if stillFor > Self.stillnessSeconds, angle > settings.clearAngle + 5 {
            rate = LidAngleSensor.restingRate
        } else if angle < settings.clearAngle + Self.watchDegrees {
            rate = LidAngleSensor.idleRate
        } else {
            rate = LidAngleSensor.restingRate
        }
        sensor.setPollRate(rate)

        if progress > 0.001 {
            activate()
        } else if approaching {
            activate(showingOverlay: false)
        } else if capture.isRunning {
            deactivate()
        }
    }

    /// How far above the clear angle the capture stream is brought up, once the
    /// lid is actually on its way down.
    private static let preRollDegrees: Double = 12
    /// Within this much of the clear angle, poll often enough to catch the
    /// start of a fast close. Above it, the lid is nowhere near mattering.
    private static let watchDegrees: Double = 30
    /// Closing faster than this counts as intent, rather than a hand resting
    /// on the screen or sensor noise.
    private static let closingDegreesPerSecond: Double = 2
    /// How long the hinge has to hold still before the slow watch takes over.
    private static let stillnessSeconds: TimeInterval = 2

    private func activate(showingOverlay: Bool = true) {
        guard !isActive || !showingOverlay else { return }
        if showingOverlay { isActive = true }
        // Note there's no permission check here on purpose. Asking
        // ScreenCaptureKit and letting it fail is what makes macOS show its own
        // "would like to record this screen" prompt and list the app in
        // Privacy settings — refusing to try would leave the user with no way
        // to grant it. Nothing reaches the screen until a frame actually
        // arrives, so a denied attempt is invisible rather than a black
        // overlay.
        //
        // Once refused, stop asking until the permission actually changes.
        // Retrying on a timer burns real CPU for nothing — a denied
        // ScreenCaptureKit start is not cheap — and it can't succeed until the
        // user grants it anyway. The first attempt is always allowed through
        // even when preflight says no, because that attempt is what makes macOS
        // show its prompt in the first place.
        if captureDeniedAt != nil, !ScreenPermission.isGranted {
            isActive = false
            return
        }

        // A shutdown may be pending from a fold that just cleared; the stream
        // is still warm, so keep it.
        pendingCaptureStop?.cancel()
        pendingCaptureStop = nil

        guard let screen = builtInScreen else { return }
        let window = self.window ?? {
            let created = OverlayWindow(screen: screen, device: device)
            created.metalView.delegate = renderer
            self.window = created
            return created
        }()
        window.reposition(on: screen)
        if showingOverlay {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.metalView.isPaused = false
        }

        guard !capture.isRunning else { return }

        let scale = screen.backingScaleFactor
        let pixelWidth = Int(screen.frame.width * scale)
        let pixelHeight = Int(screen.frame.height * scale)
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }

        Task { [capture, weak self] in
            do {
                try await capture.start(displayID: number.uint32Value,
                                        pixelWidth: pixelWidth,
                                        pixelHeight: pixelHeight)
                await MainActor.run { self?.captureDeniedAt = nil }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if self.captureDeniedAt == nil {
                        Log.error("couldn't start capture: \(error.localizedDescription)")
                        AppDelegate.shared?.reportCaptureFailure(error)
                    }
                    self.captureDeniedAt = Date()
                    self.deactivateImmediately()
                }
            }
        }
    }

    private func didRenderFrame(progress: Float) {
        guard let window, isActive else { return }

        // Stay invisible until there is actually a captured frame to bend —
        // the first few milliseconds of a stream have nothing in them, and
        // showing the empty overlay would flash the screen black.
        guard capture.currentTexture() != nil else {
            window.alphaValue = 0
            return
        }

        // Fade in over the first sliver of movement so the dark surround never
        // pops; past that the fold itself carries the effect.
        window.alphaValue = CGFloat(min(progress / 0.05, 1))

        if progress > 0.12 { didReachBend = true }

        // Fully cleared: put everything back to sleep.
        if progress <= 0.0008, renderer.targetProgress <= 0.0008 {
            deactivate()
            if didReachBend {
                didReachBend = false
                if settings.soundEnabled { click.play() }
            }
        }
    }

    /// Takes the overlay off screen at once, but leaves the capture stream
    /// running for a few seconds.
    ///
    /// Starting a ScreenCaptureKit stream takes a moment, and a lid that has
    /// just cleared is very often moved again straight away — tearing the
    /// stream down on every pass puts a visible delay at the start of each
    /// fold. Anything that genuinely ends the effect stops it at once instead.
    private func deactivate(lingering: Bool = true) {
        if !lingering {
            pendingCaptureStop?.cancel()
            pendingCaptureStop = nil
        }

        if isActive {
            isActive = false
            window?.metalView.isPaused = true
            window?.alphaValue = 0
            window?.orderOut(nil)
        }

        guard lingering else {
            Task { [capture] in await capture.stop() }
            return
        }

        // A countdown already running is left alone. This is called every time
        // the angle changes while the lid is open, and cancelling and
        // rescheduling on each one would defer the shutdown indefinitely.
        guard pendingCaptureStop == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCaptureStop = nil
            Task { [capture = self.capture] in await capture.stop() }
        }
        pendingCaptureStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func deactivateImmediately() { deactivate(lingering: false) }

    private func screenParametersChanged() {
        if let screen = builtInScreen { window?.reposition(on: screen) }
        // Resolution or display arrangement changed under us; restart the
        // capture at the new size on the next fold.
        if isActive {
            deactivateImmediately()
            reevaluate()
        }
    }

    /// Used by the settings window's preview slider.
    func previewProgress() -> Float { renderer.smoothedProgress }

    enum ControllerError: LocalizedError {
        case noMetal

        var errorDescription: String? {
            switch self {
            case .noMetal: return "This Mac has no Metal device."
            }
        }
    }
}
