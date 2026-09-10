import Foundation
import IOKit
import IOKit.hid

/// Reads the hinge angle from the MacBook's own lid angle sensor.
///
/// The sensor shows up as an Apple HID device ("las") on the sensor usage page
/// (0x20) with usage 0x8A. It pushes input reports of the form
/// `[reportID, angleLow, angleHigh]`, so we listen rather than poll. A feature
/// report on the same ID gives the current angle on demand, which we use once at
/// startup so the first frame isn't waiting on the sensor to tick.
final class LidAngleSensor {
    /// Latest angle in degrees, or nil if the sensor hasn't reported yet.
    private(set) var angle: Double?
    /// Called on the main queue whenever a new angle arrives.
    var onChange: ((Double) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffer = [UInt8](repeating: 0, count: 64)

    /// True when the machine actually has a lid angle sensor.
    var isAvailable: Bool { device != nil }

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
        angle = readFeatureReport()
    }

    func start() {
        guard let device else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        reportBuffer.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer.baseAddress!, CFIndex(buffer.count),
                { context, _, _, _, _, report, length in
                    guard let context else { return }
                    let sensor = Unmanaged<LidAngleSensor>.fromOpaque(context).takeUnretainedValue()
                    sensor.handleReport(UnsafeBufferPointer(start: report, count: Int(length)))
                },
                context
            )
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func handleReport(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let degrees = Self.parse(bytes) else { return }
        angle = degrees
        onChange?(degrees)
    }

    /// Pulls the angle on demand. Used once at startup, and as a fallback if the
    /// sensor stops pushing reports (it goes quiet while the lid is still).
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
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}
