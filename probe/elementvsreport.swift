import Foundation
import IOKit
import IOKit.hid
import QuartzCore

// The element read is 58x cheaper than the feature report — but only useful if
// it tracks the hardware just as closely. If it merely mirrors the 1 Hz push
// reports it is stale, and cheapness buys nothing. Both are polled side by side
// here, and the count of distinct values each sees decides it.

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
    print("no sensor"); exit(1)
}
_ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
// Put back the interval the probe before this one changed.
IOHIDDeviceSetProperty(device, "ReportInterval" as CFString, NSNumber(value: 8000))

let elements = (IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement]) ?? []
guard let angleElement = elements.first(where: { IOHIDElementGetUsage($0) == 0x47F }) else {
    print("no angle element"); exit(1)
}

var value = Unmanaged.passUnretained(IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, angleElement, 0, 0))
func element() -> Int? {
    guard IOHIDDeviceGetValue(device, angleElement, &value) == kIOReturnSuccess else { return nil }
    return IOHIDValueGetIntegerValue(value.takeUnretainedValue())
}
func report() -> Int? {
    var buf = [UInt8](repeating: 0, count: 8); var len = CFIndex(8)
    guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len) == kIOReturnSuccess,
          len >= 3 else { return nil }
    return Int(buf[1]) | (Int(buf[2]) << 8)
}

// Waits for the lid rather than racing the person reading the instruction:
// runs until it has seen enough movement to judge, or gives up after 90s.
print("--- waiting for lid movement (up to 90s) ---")
let start = CACurrentMediaTime()
var elementChanges: [(Double, Int)] = [], reportChanges: [(Double, Int)] = []
var lastE = -1, lastR = -1, polls = 0
while CACurrentMediaTime() - start < 90, elementChanges.count < 40, reportChanges.count < 40 {
    let t = CACurrentMediaTime() - start
    if let e = element(), e != lastE { elementChanges.append((t, e)); lastE = e }
    if let r = report(), r != lastR { reportChanges.append((t, r)); lastR = r }
    polls += 1
    usleep(3000)   // ~300 Hz
}

func rate(_ xs: [(Double, Int)]) -> String {
    guard xs.count > 2 else { return "too few" }
    let gaps = zip(xs.dropFirst(), xs).map { $0.0 - $1.0 }.sorted()
    return String(format: "%d changes, median gap %.0f ms", xs.count, gaps[gaps.count/2] * 1000)
}
print("polled \(polls) times in 15s")
print("  element:  \(rate(elementChanges))")
print("  report:   \(rate(reportChanges))")
let agree = zip(elementChanges.map { $0.1 }, reportChanges.map { $0.1 }).filter { $0 == $1 }.count
print("  values agree on \(agree) of \(min(elementChanges.count, reportChanges.count)) compared")
