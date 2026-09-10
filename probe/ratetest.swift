import Foundation
import IOKit
import IOKit.hid
import QuartzCore

// Measures what the lid angle sensor can actually give us:
//   · how often pushed input reports arrive
//   · how often a polled feature report shows a NEW value
//   · whether report IDs 2 and 3 carry anything finer than whole degrees
// Polling faster than the hardware updates buys nothing, so this decides it.

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
    print("no sensor"); exit(1)
}
_ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

let start = CACurrentMediaTime()
var inputTimes: [Double] = []
var inputValues: [Int] = []

var reportBuffer = [UInt8](repeating: 0, count: 64)
IOHIDDeviceRegisterInputReportCallback(device, &reportBuffer, CFIndex(reportBuffer.count), { _, _, _, _, _, bytes, len in
    guard len >= 3 else { return }
    let value = Int(bytes[1]) | (Int(bytes[2]) << 8)
    inputTimes.append(CACurrentMediaTime() - start)
    inputValues.append(value)
}, nil)
IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

func feature(_ id: Int, _ size: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: size)
    var length = CFIndex(size)
    guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), &buffer, &length) == kIOReturnSuccess
    else { return nil }
    return Array(buffer.prefix(Int(length)))
}

// Time a single feature-report read, so we know what polling would cost.
var readCost = 0.0
for _ in 0..<200 {
    let t0 = CACurrentMediaTime()
    _ = feature(1, 8)
    readCost += CACurrentMediaTime() - t0
}
print(String(format: "feature read cost: %.3f ms each", readCost / 200 * 1000))

print("--- 20s: MOVE THE LID SLOWLY, open and closed a few times ---")

var polls = 0
var pollChanges: [(Double, Int)] = []
var lastPolled = -1
var report2Changes = Set<String>()
var report3Samples: [(Double, Int, String)] = []
var lastReport3 = ""

let deadline = start + 20.0
while CACurrentMediaTime() < deadline {
    // Drain pushed reports without blocking the poll loop.
    CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.0005, true)

    if let bytes = feature(1, 8), bytes.count >= 3 {
        polls += 1
        let value = Int(bytes[1]) | (Int(bytes[2]) << 8)
        if value != lastPolled {
            pollChanges.append((CACurrentMediaTime() - start, value))
            lastPolled = value
        }
    }
    if let bytes = feature(2, 8) {
        report2Changes.insert(bytes.map { String(format: "%02x", $0) }.joined())
    }
    if let bytes = feature(3, 8) {
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        if hex != lastReport3 {
            report3Samples.append((CACurrentMediaTime() - start, lastPolled, hex))
            lastReport3 = hex
        }
    }
}

let elapsed = CACurrentMediaTime() - start
print(String(format: "\npolled %d times in %.1fs (%.0f Hz attempted)", polls, elapsed, Double(polls) / elapsed))
print("pushed input reports: \(inputTimes.count)")
print("distinct values seen by POLLING: \(pollChanges.count)")
print("distinct values seen by PUSH:    \(Set(inputValues).count) across \(inputValues.count) reports")

func intervals(_ times: [Double]) -> String {
    guard times.count > 2 else { return "n/a" }
    let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0.0005 }
    guard !gaps.isEmpty else { return "n/a" }
    let sorted = gaps.sorted()
    return String(format: "min %.1f ms, median %.1f ms, max %.1f ms",
                  sorted.first! * 1000, sorted[sorted.count / 2] * 1000, sorted.last! * 1000)
}
print("gap between NEW polled values: \(intervals(pollChanges.map { $0.0 }))")
print("gap between pushed reports:    \(intervals(inputTimes))")

print("\nreport 2 distinct payloads: \(report2Changes.count) -> \(report2Changes.prefix(4).joined(separator: ", "))")
print("report 3 changed \(report3Samples.count) times; first 12 (time, angle, bytes):")
for sample in report3Samples.prefix(12) {
    print(String(format: "  %.2fs angle=%d  [%@]", sample.0, sample.1, sample.2))
}
