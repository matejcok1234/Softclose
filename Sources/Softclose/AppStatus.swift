import Foundation

/// Live runtime state, separate from the persisted `Settings`.
///
/// It exists so the settings window can show a moving readout without being
/// rebuilt: publishing the angle here lets SwiftUI update the one label that
/// changed, instead of the whole view being reconstructed underneath a slider
/// the user is still dragging.
@MainActor
final class AppStatus: ObservableObject {
    static let shared = AppStatus()

    /// True only while the settings window is open. Publishing an angle ten
    /// times a second wakes SwiftUI's machinery whether or not anything is on
    /// screen to show it, and for a menu bar app that is almost never.
    var isObserved = false

    @Published var angle: Double?
    @Published var sensorAvailable = false
    @Published var permissionGranted = false
    /// Eased fold amount, 0...1. Throttled — the renderer produces this at the
    /// display's refresh rate and SwiftUI has no use for 120 updates a second.
    @Published var progress: Double = 0

    private var lastProgressPublish = Date.distantPast

    func publish(angle newValue: Double?) {
        guard isObserved else { return }
        angle = newValue
    }

    func publish(progress newValue: Double) {
        guard isObserved else { return }
        guard abs(newValue - progress) > 0.005 || (newValue == 0 && progress != 0) else { return }
        guard Date().timeIntervalSince(lastProgressPublish) > 0.05 else { return }
        lastProgressPublish = Date()
        progress = newValue
    }

    private init() {}
}
