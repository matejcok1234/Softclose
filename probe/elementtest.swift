import Foundation
import IOKit
import IOKit.hid
import QuartzCore

// Is there a cheaper way to read the hinge than a feature report?
//   1. IOHIDDeviceGetValue on the sensor's own element
//   2. asking the device to push reports faster, so polling isn't needed at all

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
    print("no sensor"); exit(1)
}
_ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

// --- 1. Elements
let elements = (IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement]) ?? []
print("elements: \(elements.count)")
for e in elements.prefix(6) {
    print(String(format: "  usagePage=0x%02X usage=0x%02X type=%d min=%d max=%d",
                 IOHIDElementGetUsagePage(e), IOHIDElementGetUsage(e),
                 IOHIDElementGetType(e).rawValue,
                 IOHIDElementGetLogicalMin(e), IOHIDElementGetLogicalMax(e)))
}

if let element = elements.first(where: { IOHIDElementGetUsagePage($0) == 0x20 && IOHIDElementGetType($0) != kIOHIDElementTypeCollection }) {
    var value = Unmanaged.passUnretained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0))
    let t0 = CACurrentMediaTime()
    var ok = 0
    for _ in 0..<300 {
        if IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess { ok += 1 }
    }
    let per = (CACurrentMediaTime() - t0) / 300 * 1000
    print(String(format: "IOHIDDeviceGetValue: %.3f ms each (%d/300 ok)", per, ok))
    if ok > 0 {
        print("  reads: \(IOHIDValueGetIntegerValue(value.takeUnretainedValue()))")
    }
}

// Baseline for comparison.
var buf = [UInt8](repeating: 0, count: 8)
let t1 = CACurrentMediaTime()
for _ in 0..<300 { var len = CFIndex(8); _ = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len) }
print(String(format: "IOHIDDeviceGetReport: %.3f ms each", (CACurrentMediaTime() - t1) / 300 * 1000))

// --- 2. Can the device be asked to report faster?
for key in ["ReportInterval", "IOHIDReportInterval"] {
    let before = IOHIDDeviceGetProperty(device, key as CFString)
    let interval: CFNumber = NSNumber(value: 16000)   // 16 ms
    let set = IOHIDDeviceSetProperty(device, key as CFString, interval)
    let after = IOHIDDeviceGetProperty(device, key as CFString)
    print("\(key): before=\(String(describing: before)) setOK=\(set) after=\(String(describing: after))")
}

var count = 0
var report = [UInt8](repeating: 0, count: 64)
IOHIDDeviceRegisterInputReportCallback(device, &report, 64, { _, _, _, _, _, _, _ in
    count += 1
}, nil)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 5.0, false)
print("input reports in 5s after asking for 16ms: \(count)  (\(count/5) Hz)")
