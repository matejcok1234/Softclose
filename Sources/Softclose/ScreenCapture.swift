import AppKit
import Foundation
import ScreenCaptureKit
import CoreVideo
import Metal

/// Captures the built-in display with ScreenCaptureKit and hands each frame to
/// the renderer as a Metal texture.
///
/// Our own windows are excluded from the filter — the overlay is showing the
/// capture, so including it would feed the picture back into itself.
final class ScreenCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private let device: MTLDevice
    private var stream: SCStream?
    private var textureCache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "app.softclose.capture", qos: .userInteractive)

    /// Most recent frame. Read on the render thread, written on the capture queue.
    private let lock = NSLock()
    private var latest: CVMetalTexture?

    private(set) var isRunning = false

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    private func clearLatest() {
        lock.lock()
        latest = nil
        lock.unlock()
    }

    /// Returns the newest captured frame, if one has landed.
    func currentTexture() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest else { return nil }
        return CVMetalTextureGetTexture(latest)
    }

    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) async throws {
        guard !isRunning else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let ourApp = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: ourApp.map { [$0] } ?? [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.capturesAudio = false
        config.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
        Log.info("capture started \(pixelWidth)x\(pixelHeight)")
    }

    func stop() async {
        guard let stream, isRunning else { return }
        isRunning = false
        self.stream = nil
        do { try await stream.stopCapture() } catch { Log.warn("stopCapture: \(error)") }
        clearLatest()
        Log.info("capture stopped")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let textureCache
        else { return }

        // Skip frames the system marks as idle (nothing on screen changed).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusValue = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusValue),
           status != .complete, status != .started {
            return
        }

        var texture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
            0, &texture
        )
        guard result == kCVReturnSuccess, let texture else { return }

        lock.lock()
        latest = texture
        lock.unlock()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("stream stopped: \(error.localizedDescription)")
        isRunning = false
        self.stream = nil
    }

    enum CaptureError: LocalizedError {
        case displayNotFound

        var errorDescription: String? {
            switch self {
            case .displayNotFound: return "Couldn't find the built-in display to capture."
            }
        }
    }
}

/// Screen Recording permission, checked without triggering a prompt we can't undo.
enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
