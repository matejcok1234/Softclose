import AppKit
import MetalKit

/// The window the fold is drawn in: the whole built-in display, above
/// everything, and completely transparent to the mouse. It is only on screen
/// while the lid is actually moving.
final class OverlayWindow: NSWindow {
    let metalView: MTKView

    init(screen: NSScreen, device: MTLDevice) {
        metalView = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true
        metalView.preferredFramesPerSecond = 120
        metalView.autoResizeDrawable = true
        metalView.layer?.isOpaque = true

        // Deliberately the four-argument initialiser: NSWindow's `screen:`
        // variant dispatches back through the designated initialiser, which a
        // Swift subclass with stored properties hasn't synthesised, and traps.
        // The frame is set straight after instead.
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        setFrame(screen.frame, display: false)

        contentView = metalView
        level = Self.coveringLevel
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0
        hasShadow = false
        ignoresMouseEvents = true
        // Readable on purpose: the capture filter already keeps the overlay out
        // of our own stream, and people want to be able to screen-record the
        // fold. Excluding it would make it invisible to QuickTime and ⌘⇧5.
        sharingType = .readOnly
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        displaysWhenScreenProfileChanges = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(on screen: NSScreen) {
        setFrame(screen.frame, display: false)
    }

    /// The settings window has to sit above the fold to be usable while it is
    /// on screen, and the overlay is above everything by design. Rather than
    /// demote the overlay — which would let other apps' windows sit on top of
    /// the bent image — the settings window is raised past it, and this is the
    /// level it has to clear.
    static let coveringLevel = NSWindow.Level.screenSaver
    static let settingsLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
}
