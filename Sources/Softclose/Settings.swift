import Foundation
import Combine
import os

enum Log {
    private static let logger = Logger(subsystem: "io.github.matejcok1234.softclose", category: "softclose")
    // notice, not info: info-level entries are memory-only, so they vanish
    // before you can read them back with `log show`.
    static func info(_ message: String) { logger.notice("\(message, privacy: .public)") }
    static func warn(_ message: String) { logger.warning("\(message, privacy: .public)") }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}

/// The three built-in looks. Each is a weighting of the same three knobs, so
/// picking a style just moves the sliders.
enum BendStyle: String, CaseIterable, Identifiable {
    case silk, shade, frost, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .silk: return "Silk"
        case .shade: return "Shade"
        case .frost: return "Frost"
        case .custom: return "Custom"
        }
    }

    var blurb: String {
        switch self {
        case .silk: return "Mostly fold. The desktop tips away and barely softens."
        case .shade: return "The fold falls into shadow as the hinge closes."
        case .frost: return "Softens to frosted glass on the way down."
        case .custom: return "Your own mix."
        }
    }

    /// perspective, blur, shadow — each 0...1
    var preset: (perspective: Double, blur: Double, shadow: Double)? {
        switch self {
        case .silk: return (1.00, 0.35, 0.30)
        case .shade: return (0.70, 0.40, 1.00)
        case .frost: return (0.55, 1.00, 0.50)
        case .custom: return nil
        }
    }
}

/// User-facing settings, persisted to UserDefaults. Observed by the settings
/// window; read every frame by the renderer.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var style: BendStyle { didSet { applyPresetIfNeeded(from: oldValue) } }
    @Published var perspective: Double { didSet { persist() } }
    @Published var blur: Double { didSet { persist() } }
    @Published var shadow: Double { didSet { persist() } }
    /// Above this hinge angle the effect is fully cleared and capture stops.
    @Published var clearAngle: Double { didSet { persist() } }
    @Published var soundEnabled: Bool { didSet { persist() } }
    @Published var launchAtLogin: Bool { didSet { persist() } }
    /// When set, the angle comes from the slider instead of the sensor.
    @Published var manualAngle: Double? { didSet { persist() } }

    // The effect's own constants, exposed so the look can be tuned rather than
    // recompiled. `perspective`, `blur` and `shadow` scale these.
    /// How far the sheet folds at perspective 1.0.
    @Published var maxFoldDegrees: Double { didSet { persist() } }
    /// Blur radius at blur 1.0, in half-resolution texels.
    @Published var maxBlurRadius: Double { didSet { persist() } }
    /// Eye distance in sheet-heights. Nearer is a wider, more dramatic lens.
    @Published var cameraDistance: Double { didSet { persist() } }
    /// Spring constant for the easing. Higher tracks the hinge more tightly.
    @Published var springStiffness: Double { didSet { persist() } }
    @Published var isPaused: Bool = false

    private var isApplyingPreset = false

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "style": BendStyle.silk.rawValue,
            "perspective": 1.00,
            "blur": 0.35,
            "shadow": 0.30,
            "clearAngle": 95.0,
            "soundEnabled": true,
            "launchAtLogin": false,
            "maxFoldDegrees": 62.0,
            "maxBlurRadius": 18.0,
            "cameraDistance": 3.0,
            "springStiffness": 220.0,
        ])
        style = BendStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .silk
        perspective = defaults.double(forKey: "perspective")
        blur = defaults.double(forKey: "blur")
        shadow = defaults.double(forKey: "shadow")
        clearAngle = defaults.double(forKey: "clearAngle")
        soundEnabled = defaults.bool(forKey: "soundEnabled")
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        manualAngle = defaults.object(forKey: "manualAngle") as? Double
        maxFoldDegrees = defaults.double(forKey: "maxFoldDegrees")
        maxBlurRadius = defaults.double(forKey: "maxBlurRadius")
        cameraDistance = defaults.double(forKey: "cameraDistance")
        springStiffness = defaults.double(forKey: "springStiffness")
    }

    /// Back to the shipped look, keeping the calibrated clear angle and the
    /// general preferences — those aren't part of "the look".
    func resetLook() {
        isApplyingPreset = true
        style = .silk
        perspective = 1.00
        blur = 0.35
        shadow = 0.30
        maxFoldDegrees = 62
        maxBlurRadius = 18
        cameraDistance = 3.0
        springStiffness = 220
        isApplyingPreset = false
        persist()
    }

    /// On a first run, take the angle the lid is sitting at as the angle the
    /// user keeps it at, and clear just below it. A fixed default would either
    /// leave a permanent fold on a laptop held at 90°, or wait too long to
    /// start on one held wide open.
    func calibrateClearAngleIfNeeded(restingAt angle: Double?) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "didCalibrate") == nil else { return }
        defaults.set(true, forKey: "didCalibrate")
        guard let angle, angle > 40 else { return }
        clearAngle = min(max(angle - 3, 60), 130)
        Log.info("calibrated clear angle to \(clearAngle)° from a resting \(angle)°")
    }

    private func applyPresetIfNeeded(from previous: BendStyle) {
        guard !isApplyingPreset, let preset = style.preset else { persist(); return }
        isApplyingPreset = true
        perspective = preset.perspective
        blur = preset.blur
        shadow = preset.shadow
        isApplyingPreset = false
        persist()
    }

    /// Nudging a slider by hand drops you into Custom, which is what you'd expect.
    func markCustomised() {
        guard !isApplyingPreset, style != .custom else { return }
        isApplyingPreset = true
        style = .custom
        isApplyingPreset = false
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(style.rawValue, forKey: "style")
        defaults.set(perspective, forKey: "perspective")
        defaults.set(blur, forKey: "blur")
        defaults.set(shadow, forKey: "shadow")
        defaults.set(clearAngle, forKey: "clearAngle")
        defaults.set(soundEnabled, forKey: "soundEnabled")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(maxFoldDegrees, forKey: "maxFoldDegrees")
        defaults.set(maxBlurRadius, forKey: "maxBlurRadius")
        defaults.set(cameraDistance, forKey: "cameraDistance")
        defaults.set(springStiffness, forKey: "springStiffness")
        if let manualAngle {
            defaults.set(manualAngle, forKey: "manualAngle")
        } else {
            defaults.removeObject(forKey: "manualAngle")
        }
    }
}

/// Maps a hinge angle to 0 (fully open, no effect) ... 1 (shut).
/// Eased so the first few degrees off the resting angle already read as motion,
/// the way the lid feels when you start to close it.
struct BendCurve {
    /// The screen has cut out well before this, but the sensor keeps reporting.
    static let closedAngle: Double = 5.0

    static func progress(angle: Double, clearAngle: Double) -> Double {
        let span = max(clearAngle - closedAngle, 1)
        let linear = 1 - ((angle - closedAngle) / span)
        let clamped = min(max(linear, 0), 1)
        // ease-in-out so it settles instead of arriving flat
        return clamped * clamped * (3 - 2 * clamped)
    }
}
