import Foundation
import IOKit
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = set.first else {
    print("no device"); exit(1)
}
_ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

var report = [UInt8](repeating: 0, count: 64)
IOHIDDeviceRegisterInputReportCallback(device, &report, CFIndex(report.count), { _, result, _, type, reportID, bytes, len in
    let arr = UnsafeBufferPointer(start: bytes, count: Int(len)).map { String(format: "%02x", $0) }.joined(separator: " ")
    print("INPUT report id=\(reportID) type=\(type.rawValue) len=\(len) bytes=[\(arr)]")
}, nil)

IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
print("--- listening 6s for input reports (move the lid if you can) ---")
CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 6.0, false)
print("--- done listening ---")
