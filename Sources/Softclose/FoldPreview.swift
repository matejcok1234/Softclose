import AppKit
import MetalKit
import ScreenCaptureKit
import SwiftUI

/// The fold, running live inside the settings window.
///
/// It renders through the same `BendRenderer` and the same shaders as the
/// overlay, so what you tune is what you get. The source is a single still of
/// the desktop rather than a running capture — a preview is not worth a second
/// video stream — and it loops a scripted lid close, because half the settings
/// (the spring's stiffness and settle) only mean anything in motion.
struct FoldPreview: NSViewRepresentable {
    @ObservedObject var settings: Settings

    func makeCoordinator() -> Coordinator { Coordinator(settings: settings) }

    func makeNSView(context: Context) -> MTKView { context.coordinator.view }

    func updateNSView(_ view: MTKView, context: Context) {}

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        let view: MTKView
        private var renderer: BendRenderer?
        private var source: MTLTexture?
        private let settings: Settings
        private let started = CACurrentMediaTime()

        init(settings: Settings) {
            self.settings = settings
            let device = MTLCreateSystemDefaultDevice()
            view = MTKView(frame: .zero, device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = true
            view.enableSetNeedsDisplay = false
            view.preferredFramesPerSecond = 60
            view.autoResizeDrawable = true
            view.layer?.isOpaque = true

            guard let device else { return }
            // A placeholder is in place from the first frame, so the panel is
            // never empty while the real desktop still is being fetched.
            source = MockDesktop.texture(device: device)
            renderer = try? BendRenderer(device: device,
                                         textureProvider: { [weak self] in self?.source },
                                         settings: settings)
            renderer?.progressProvider = { [weak self] in self?.scriptedProgress() ?? 0 }
            view.delegate = renderer

            Task { [weak self] in
                if let snapshot = await DesktopSnapshot.capture(device: device) {
                    self?.source = snapshot
                }
            }
        }

        func stop() {
            view.isPaused = true
            view.delegate = nil
            renderer = nil
        }

        /// A lid closing and opening again, on a loop. Held still instead when
        /// the angle is being dragged by hand, since that is already a preview.
        private func scriptedProgress() -> Float {
            if let manual = settings.manualAngle {
                return Float(BendCurve.progress(angle: manual, clearAngle: settings.clearAngle))
            }

            // Swept from just above the clear angle so the whole effect is
            // always in shot, whatever the clear angle is set to.
            let open = settings.clearAngle + 8
            let shut = 8.0
            let t = (CACurrentMediaTime() - started).truncatingRemainder(dividingBy: 5.2)

            let angle: Double
            switch t {
            case ..<0.6:  angle = open
            case ..<1.8:  angle = open - (open - shut) * pow((t - 0.6) / 1.2, 0.85)
            case ..<2.9:  angle = shut
            case ..<4.1:  angle = shut + (open - shut) * pow((t - 2.9) / 1.2, 1.2)
            default:      angle = open
            }
            return Float(BendCurve.progress(angle: angle, clearAngle: settings.clearAngle))
        }
    }
}

/// One still of the desktop, for the preview to fold.
enum DesktopSnapshot {
    static func capture(device: MTLDevice) async -> MTLTexture? {
        guard ScreenPermission.isGranted else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let ourApp = content.applications.first {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            let filter = SCContentFilter(display: display,
                                         excludingApplications: ourApp.map { [$0] } ?? [],
                                         exceptingWindows: [])
            let config = SCStreamConfiguration()
            // Small on purpose: it is being drawn into a panel a few hundred
            // points wide, and the blur samples down the mip chain anyway.
            config.width = 1280
            config.height = Int(1280.0 * Double(display.height) / Double(display.width))
            config.showsCursor = false
            config.captureResolution = .nominal

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: config)
            return try await MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false])
        } catch {
            Log.warn("preview snapshot: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Stand-in for the desktop: shown for the instant before the real snapshot
/// lands, and permanently on a Mac that hasn't granted Screen Recording — the
/// look can still be tuned there even though the effect can't run.
enum MockDesktop {
    static func texture(device: MTLDevice) -> MTLTexture? {
        let width = 1280, height = 800
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        let wallpaper = CGGradient(colorsSpace: colorSpace, colors: [
            CGColor(red: 0.15, green: 0.22, blue: 0.42, alpha: 1),
            CGColor(red: 0.52, green: 0.28, blue: 0.45, alpha: 1),
            CGColor(red: 0.92, green: 0.55, blue: 0.36, alpha: 1),
        ] as CFArray, locations: [0, 0.55, 1])!
        context.drawLinearGradient(wallpaper, start: CGPoint(x: 0, y: height),
                                   end: CGPoint(x: width, y: 0), options: [])

        context.setFillColor(CGColor(gray: 0.1, alpha: 0.55))
        context.fill(CGRect(x: 0, y: height - 28, width: width, height: 28))

        func window(_ rect: CGRect) {
            context.setFillColor(CGColor(gray: 0.13, alpha: 0.97))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
            context.setFillColor(CGColor(gray: 0.7, alpha: 0.65))
            for row in 0..<Int((rect.height - 60) / 22) {
                let width = rect.width * (row % 3 == 0 ? 0.72 : 0.46)
                context.fill(CGRect(x: rect.minX + 20, y: rect.maxY - 56 - CGFloat(row) * 22,
                                    width: width, height: 7))
            }
        }
        window(CGRect(x: 80, y: 130, width: 550, height: 480))
        window(CGRect(x: 570, y: 80, width: 620, height: 550))

        context.setFillColor(CGColor(gray: 0.9, alpha: 0.22))
        context.addPath(CGPath(roundedRect: CGRect(x: width / 2 - 230, y: 12, width: 460, height: 56),
                               cornerWidth: 16, cornerHeight: 16, transform: nil))
        context.fillPath()

        guard let image = context.makeImage() else { return nil }
        return try? MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false])
    }
}
