import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?

    private let settings = Settings.shared
    private var controller: BendController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var angleMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var permissionMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        buildStatusItem()

        do {
            let controller = try BendController(settings: settings)
            controller.onAngleChange = { [weak self] angle in
                AppStatus.shared.angle = angle
                self?.updateMenu(angle: angle)
            }
            controller.start()
            self.controller = controller
            AppStatus.shared.sensorAvailable = controller.sensorIsAvailable
            AppStatus.shared.permissionGranted = ScreenPermission.isGranted
            updateMenu(angle: controller.currentAngle)
        } catch {
            presentFatal(error)
            return
        }

        registerHotKey()

        if !ScreenPermission.isGranted {
            promptForPermission()
            // The system prompt only fires on the next capture attempt, which
            // may be a long way off — capture doesn't start until the lid drops
            // below the clear angle. So put the list itself in front of the
            // user rather than leaving a menu bar app that silently does
            // nothing until they happen to close their laptop.
            ScreenPermission.openSettings()
        }

        // First run: show what the app actually is. A menu bar icon with no
        // window is an easy thing to install and never find again.
        if !UserDefaults.standard.bool(forKey: "didShowSettings") {
            UserDefaults.standard.set(true, forKey: "didShowSettings")
            openSettings()
        }
        if !(controller?.sensorIsAvailable ?? false) {
            presentSensorMissing()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusItem.self
        _ = item
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Softclose")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let angleItem = NSMenuItem(title: "Hinge —", action: nil, keyEquivalent: "")
        angleItem.isEnabled = false
        menu.addItem(angleItem)
        angleMenuItem = angleItem

        menu.addItem(.separator())

        let permission = NSMenuItem(title: "Allow Screen Recording…",
                                    action: #selector(openPermissionSettings), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        permissionMenuItem = permission

        let pause = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "b")
        pause.keyEquivalentModifierMask = [.option, .command]
        pause.target = self
        menu.addItem(pause)
        pauseMenuItem = pause

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Softclose", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        status.menu = menu
        statusItem = status
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        settingsWindow = nil
    }

    @objc private func openPermissionSettings() {
        ScreenPermission.request()
        ScreenPermission.openSettings()
    }

    private func updateMenu(angle: Double?) {
        let granted = ScreenPermission.isGranted
        permissionMenuItem?.isHidden = granted
        if AppStatus.shared.permissionGranted != granted {
            AppStatus.shared.permissionGranted = granted
        }
        if !granted {
            angleMenuItem?.title = "Needs Screen Recording"
            statusItem?.button?.appearsDisabled = true
            return
        }
        if let angle {
            angleMenuItem?.title = String(format: "Hinge at %.0f°", angle)
        } else {
            angleMenuItem?.title = "Hinge —"
        }
        pauseMenuItem?.title = settings.isPaused ? "Resume" : "Pause"
        statusItem?.button?.appearsDisabled = settings.isPaused
    }

    @objc func togglePause() {
        settings.isPaused.toggle()
        updateMenu(angle: controller?.currentAngle)
    }

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(settings: settings,
                                status: AppStatus.shared,
                                onRequestPermission: { ScreenPermission.openSettings() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Softclose"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Above the overlay: the fold covers everything, and settings you can't
        // see while the effect is running would be settings you can't tune.
        window.level = OverlayWindow.settingsLevel
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    // MARK: - Hot key
    //
    // Carbon's hot key API is old but it is the one that doesn't ask for
    // Accessibility permission, which matters for an app whose whole pitch is
    // that it doesn't need any.

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if hotKeyID.id == 1 {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AppDelegate.shared?.togglePause() }
                }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x42_4E_44_59), id: 1) // 'BNDY'
        RegisterEventHotKey(UInt32(kVK_ANSI_B),
                            UInt32(optionKey | cmdKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }

    // MARK: - Alerts

    /// Asks the system rather than the user.
    ///
    /// `CGRequestScreenCaptureAccess` puts up macOS's own prompt and, more
    /// importantly, registers Softclose in the Screen Recording list so there is
    /// something to switch on. A modal `NSAlert` here was worse in two ways: it
    /// blocks the main thread of a menu bar app that has no window on screen,
    /// and with a full-screen app in front it opens on a Space the user never
    /// looks at. The menu carries the reminder instead.
    private func promptForPermission() {
        DispatchQueue.global(qos: .userInitiated).async {
            ScreenPermission.request()
        }
    }

    /// Same reasoning as the permission prompt: no blocking modal at launch.
    /// The settings window says so plainly, and the menu bar shows the state.
    private func presentSensorMissing() {
        Log.warn("no lid angle sensor; manual angle only")
    }

    func reportCaptureFailure(_ error: Error) {
        guard !ScreenPermission.isGranted else {
            Log.error("capture failed with permission granted: \(error.localizedDescription)")
            return
        }
        promptForPermission()
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Softclose can't start"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
