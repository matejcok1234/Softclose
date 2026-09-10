import AppKit

@main
enum Softclose {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // Menu bar only: no Dock icon, no app switcher entry.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
