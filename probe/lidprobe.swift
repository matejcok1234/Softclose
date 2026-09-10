import Foundation
import IOKit
import IOKit.hid

// Probe: find the MacBook lid angle sensor HID device and dump raw reports.
// Sensor page = 0x20 (kHIDPage_Sensor), usage 0x8A (orientation / lid angle).

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matching: [String: Any] = [
    kIOHIDPrimaryUsagePageKey: 0x20,
    kIOHIDPrimaryUsageKey: 0x8A,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    print("FAIL: IOHIDManagerOpen")
    exit(1)
}

guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
    print("FAIL: no matching HID devices (page 0x20 usage 0x8A)")
    exit(2)
}

print("Found \(set.count) device(s):")
for d in set {
    func prop(_ k: String) -> Any? { IOHIDDeviceGetProperty(d, k as CFString) }
    print("  product=\(prop(kIOHIDProductKey) ?? "?") vendor=\(prop(kIOHIDVendorIDKey) ?? "?") product-id=\(prop(kIOHIDProductIDKey) ?? "?") transport=\(prop(kIOHIDTransportKey) ?? "?")")
    print("  usagePage=\(prop(kIOHIDPrimaryUsagePageKey) ?? "?") usage=\(prop(kIOHIDPrimaryUsageKey) ?? "?") maxFeature=\(prop(kIOHIDMaxFeatureReportSizeKey) ?? "?") maxInput=\(prop(kIOHIDMaxInputReportSizeKey) ?? "?")")
}

let device = set.first!
if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
    print("WARN: IOHIDDeviceOpen failed (continuing; feature reports may still work)")
}

// Try feature reports for a few report IDs, dumping raw bytes.
for reportID in 0...3 {
    var buf = [UInt8](repeating: 0, count: 16)
    var len = CFIndex(buf.count)
    let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), &buf, &len)
    let hex = buf.prefix(max(0, Int(len))).map { String(format: "%02x", $0) }.joined(separator: " ")
    print(String(format: "feature id=%d ret=0x%08x len=%d bytes=[%@]", reportID, UInt32(bitPattern: Int32(r)), len, hex))
}

print("--- polling feature report id 1, 20 samples, 100ms apart. Move the lid! ---")
for i in 0..<20 {
    var buf = [UInt8](repeating: 0, count: 8)
    var len = CFIndex(buf.count)
    let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len)
    if r == kIOReturnSuccess {
        let bytes = Array(buf.prefix(Int(len)))
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        // candidate parses
        var cands: [String] = []
        if bytes.count >= 3 {
            let le12 = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            cands.append("LE[1,2]=\(le12)")
        }
        if bytes.count >= 2 {
            let le01 = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            cands.append("LE[0,1]=\(le01)")
        }
        print("  \(i): [\(hex)]  \(cands.joined(separator: "  "))")
    } else {
        print(String(format: "  %d: ret=0x%08x", i, UInt32(bitPattern: Int32(r))))
    }
    usleep(100_000)
}
