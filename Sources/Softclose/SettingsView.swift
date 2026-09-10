import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var status: AppStatus
    var onRequestPermission: () -> Void

    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            preview
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !status.permissionGranted { permissionNotice }
                    styles
                    knobs
                    hinge
                    advanced
                    general
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 700)
    }

    /// Deliberately above the controls rather than beside them: it stays in
    /// view while you drag anything below it, which is the whole point.
    private var preview: some View {
        // Letterboxed to the display's own proportions. The fold fills the
        // width of whatever view it is given, so a panel that isn't the shape
        // of the screen would show a desktop stretched wider than the real one.
        FoldPreview(settings: settings)
            .aspectRatio(Self.displayAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .background(Color.black)
            .overlay(alignment: .bottomTrailing) {
                Text(settings.manualAngle == nil ? "looping" : "held")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.black.opacity(0.35)))
                    .padding(8)
            }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 20))
                .foregroundStyle(settings.isPaused ? .tertiary : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Softclose").font(.system(size: 15, weight: .semibold))
                Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            FoldMeter(progress: status.progress)
            Toggle("", isOn: Binding(get: { !settings.isPaused },
                                     set: { settings.isPaused = !$0 }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Pause Softclose (⌥⌘B)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var statusLine: String {
        if settings.isPaused { return "Paused" }
        if !status.permissionGranted { return "Needs Screen Recording" }
        if settings.manualAngle != nil { return "Following the slider, not the lid" }
        guard status.sensorAvailable else { return "No lid angle sensor on this Mac" }
        guard let angle = status.angle else { return "Waiting for the hinge…" }
        return String(format: "Hinge at %.0f° · fold %.0f%%", angle, status.progress * 100)
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Softclose needs Screen Recording")
                .font(.system(size: 12, weight: .semibold))
            Text("It captures the desktop it bends. Frames are rendered on your Mac and never recorded, saved or uploaded.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Open Privacy Settings", action: onRequestPermission)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.14)))
    }

    private static var displayAspect: CGFloat {
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? NSScreen.main
        guard let frame = screen?.frame, frame.height > 0 else { return 16.0 / 10.0 }
        return frame.width / frame.height
    }

    // MARK: - Styles

    private var styles: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Style")
            HStack(spacing: 8) {
                ForEach([BendStyle.silk, .shade, .frost]) { style in
                    StyleChip(style: style, isSelected: settings.style == style) {
                        settings.style = style
                    }
                }
            }
            Text(settings.style.blurb)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(height: 14, alignment: .leading)
        }
    }

    // MARK: - The three knobs

    private var knobs: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Fold")
                Spacer()
                if settings.style == .custom {
                    Text("CUSTOM")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                }
            }
            Knob(title: "Perspective", value: $settings.perspective, settings: settings,
                 detail: "How far the sheet tips away.")
            Knob(title: "Blur", value: $settings.blur, settings: settings,
                 detail: "How much it softens on the way down.")
            Knob(title: "Shadow", value: $settings.shadow, settings: settings,
                 detail: "How far the fold falls out of the light.")
        }
    }

    // MARK: - Hinge

    private var hinge: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Hinge")

            VStack(alignment: .leading, spacing: 5) {
                LabelledValue("Clears at", String(format: "%.0f°", settings.clearAngle))
                Slider(value: $settings.clearAngle, in: 60...130)
                Text("Above this angle the desktop is left alone and capture stops. Set it just under the angle you actually hold your lid at.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Drag the angle myself", isOn: Binding(
                    get: { settings.manualAngle != nil },
                    set: { settings.manualAngle = $0 ? (status.angle ?? 90) : nil }
                ))
                .font(.system(size: 12))

                if let manual = settings.manualAngle {
                    Slider(value: Binding(get: { manual }, set: { settings.manualAngle = $0 }),
                           in: 0...130)
                    Text(String(format: "Holding the fold at %.0f°. Turn this off to follow the lid again.", manual))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ignores the sensor and parks the fold wherever you put it — the easiest way to pick a look.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Advanced
    //
    // The constants the three knobs scale. Folded away because most people
    // want a style, not a lens.

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    LabelledValue("Fold depth", String(format: "%.0f°", settings.maxFoldDegrees))
                    Slider(value: $settings.maxFoldDegrees, in: 20...90)
                    Text("The angle the sheet bends through at Perspective 100.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    LabelledValue("Blur radius", String(format: "%.0f px", settings.maxBlurRadius * 2))
                    Slider(value: $settings.maxBlurRadius, in: 2...40)
                    Text("The widest the blur goes at Blur 100.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    LabelledValue("Lens", String(format: "%.1f", settings.cameraDistance))
                    Slider(value: $settings.cameraDistance, in: 1.5...8)
                    Text("Eye distance. Lower is a wider lens, so the far edge shrinks harder.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    LabelledValue("Follow", String(format: "%.0f", settings.springStiffness))
                    Slider(value: $settings.springStiffness, in: 60...600)
                    Text("Spring stiffness. Higher tracks the hinge tightly; lower drifts and settles.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("Reset the look") { settings.resetLook() }
                    .controlSize(.small)
            }
            .padding(.top, 12)
        } label: {
            SectionLabel("Advanced")
        }
    }

    // MARK: - General

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("General")

            Toggle("Click when the desktop clears", isOn: $settings.soundEnabled)
                .font(.system(size: 12))

            Toggle("Open Softclose at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    settings.launchAtLogin = newValue
                    LoginItem.set(enabled: newValue)
                }
            ))
            .font(.system(size: 12))

            HStack {
                Text("Pause anywhere with ⌥⌘B")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit Softclose") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.top, 2)

            Divider().padding(.vertical, 2)

            HStack {
                Link(destination: URL(string: "https://buymeacoffee.com/matej2510")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "cup.and.saucer")
                        Text("Buy me a coffee")
                    }
                    .font(.system(size: 11))
                }
                Spacer()
                Text("Softclose \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Pieces

/// A small live gauge of how far the fold currently is, so the effect can be
/// tuned by feel even when the lid isn't moving.
private struct FoldMeter: View {
    let progress: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.08))
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.8))
                .frame(height: max(2, 26 * progress))
        }
        .frame(width: 6, height: 26)
        .help(String(format: "Fold %.0f%%", progress * 100))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}

private struct LabelledValue: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

private struct StyleChip: View {
    let style: BendStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(style.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct Knob: View {
    let title: String
    @Binding var value: Double
    let settings: Settings
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabelledValue(title, "\(Int(value * 100))")
            Slider(value: Binding(get: { value }, set: { newValue in
                value = newValue
                settings.markCustomised()
            }), in: 0...1)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Login item registration. SMAppService needs the app in a stable location —
/// /Applications is the one people actually use.
enum LoginItem {
    static func set(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.warn("login item: \(error.localizedDescription)")
        }
    }
}
