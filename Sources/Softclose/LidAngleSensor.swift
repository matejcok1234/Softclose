import Foundation
import IOKit
import IOKit.hid
import QuartzCore

/// Reads the hinge angle from the MacBook's own lid angle sensor.
///
/// The sensor is an Apple HID device ("las") on the sensor usage page (0x20)
/// with usage 0x8A, and it answers a feature report on ID 1 as
/// `[0x01, low, high]` — whole degrees, little-endian.
///
/// It also *pushes* input reports, which looks like the tidier design until you
/// measure it: those arrive on a fixed 1 Hz heartbeat and do not speed up when
/// the lid moves. Polling the feature report surfaces a new value roughly every
/// 100 ms — ten times the data. So polling is the primary path, and the pushed
/// reports are kept only as a free extra sample between polls.
///
/// Polling is not free: each read is about 0.5 ms of blocking IPC. It therefore
/// runs on its own queue rather than the main thread, where it would eat a
/// meaningful slice of a 120 Hz frame budget, and it runs slowly while the lid
/// is just sitting open.
final class LidAngleSensor {
    /// While the lid is somewhere we care about.
    static let activeRate: Double = 30
    /// While it is open and nothing is happening.
    static let idleRate: Double = 10

    /// Called on the main queue whenever a new angle arrives.
    var onChange: ((Double) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 64)

    private let lock = NSLock()
    private var storedAngle: Double?
    private var storedVelocity: Double = 0
    private var lastChangeTime: CFTimeInterval?

    private let pollQueue = DispatchQueue(label: "io.github.matejcok1234.softclose.sensor",
                                          qos: .userInteractive)
    private var pollTimer: DispatchSourceTimer?
    private var currentRate: Double = 0

    var isAvailable: Bool { device != nil }

    /// Latest reported angle in degrees.
    var angle: Double? {
        lock.lock()
        defer { lock.unlock() }
        return storedAngle
    }

    init() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ] as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first
        else {
            Log.warn("lid angle sensor not found on this Mac")
            return
        }

        self.manager = manager
        self.device = device
        _ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if let degrees = readFeatureReport() { record(degrees) }
    }

    func start() {
        guard let device else { return }

        // The 1 Hz push costs nothing to listen to, so take it as a free sample.
        let context = Unmanaged.passUnretained(self).toOpaque()
        reportBuffer.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer.baseAddress!, CFIndex(buffer.count),
                { context, _, _, _, _, report, length in
                    guard let context else { return }
                    let sensor = Unmanaged<LidAngleSensor>.fromOpaque(context).takeUnretainedValue()
                    if let degrees = LidAngleSensor.parse(UnsafeBufferPointer(start: report, count: Int(length))) {
                        sensor.record(degrees)
                    }
                },
                context
            )
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        setPollRate(Self.idleRate)
    }

    /// Polling only needs to outpace the hardware, which changes its answer
    /// about every 100 ms. Faster than that is pure cost.
    func setPollRate(_ hz: Double) {
        guard device != nil, hz != currentRate else { return }
        currentRate = hz

        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / hz, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, let degrees = self.readFeatureReport() else { return }
            self.record(degrees)
        }
        timer.resume()
        pollTimer = timer
    }

    /// Where the hinge has most likely reached by now.
    ///
    /// The sensor reports whole degrees about ten times a second; the display
    /// refreshes twelve times in between. Holding the last value until the next
    /// one lands makes the fold advance in visible steps, so it is carried
    /// forward at the speed the lid was last moving. The lead is capped just
    /// under one update interval — beyond that it stops being a good guess and
    /// starts being a wobble, especially where the lid changes direction.
    func extrapolatedAngle(maxLead: CFTimeInterval = 0.09) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let storedAngle else { return nil }
        guard let lastChangeTime, abs(storedVelocity) > 0.5 else { return storedAngle }
        let lead = min(CACurrentMediaTime() - lastChangeTime, maxLead)
        return storedAngle + storedVelocity * lead
    }

    /// Called from both the poll queue and the main run loop.
    private func record(_ degrees: Double) {
        lock.lock()
        let now = CACurrentMediaTime()
        let previous = storedAngle
        var changed = false

        if degrees != previous {
            if let previous, let last = lastChangeTime {
                let elapsed = now - last
                if elapsed > 0.001, elapsed < 0.5 {
                    let measured = (degrees - previous) / elapsed
                    // The reports are whole degrees, so one interval's velocity
                    // is quantised and jumpy on its own.
                    storedVelocity += (measured - storedVelocity) * 0.5
                } else {
                    storedVelocity = 0
                }
            }
            storedAngle = degrees
            lastChangeTime = now
            changed = true
        } else if let last = lastChangeTime, now - last > 0.25, storedVelocity != 0 {
            // Sitting still: stop carrying it forward.
            storedVelocity = 0
        }
        lock.unlock()

        guard changed else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(degrees) }
    }

    /// Pulls the angle on demand.
    func readFeatureReport() -> Double? {
        guard let device else { return nil }
        var buffer = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(buffer.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buffer, &length) == kIOReturnSuccess,
              length > 0
        else { return nil }
        return buffer.prefix(Int(length)).withUnsafeBufferPointer { Self.parse($0) }
    }

    /// `[0x01, low, high]` little-endian degrees. The lid tops out around 135°,
    /// so anything outside 0...180 is a torn read and gets dropped.
    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> Double? {
        guard bytes.count >= 3, bytes[0] == 0x01 else { return nil }
        let raw = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        let degrees = Double(raw)
        guard degrees >= 0, degrees <= 180 else { return nil }
        return degrees
    }

    deinit {
        pollTimer?.cancel()
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}
