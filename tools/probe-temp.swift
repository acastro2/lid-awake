// Probe: can a normal user read die temperatures on Apple silicon without root?
import Foundation
import IOKit

let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

typealias CreateWithType = @convention(c) (CFAllocator?, Int, CFDictionary?) -> Unmanaged<CFTypeRef>?
typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
typealias GetFloatValue = @convention(c) (CFTypeRef, Int64) -> Double
typealias GetIntValue = @convention(c) (CFTypeRef, Int64) -> Int64

func sym<T>(_ name: String, _ type: T.Type) -> T? {
    guard let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

guard
    let createClient = sym("IOHIDEventSystemClientCreateWithType", CreateWithType.self),
    let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self),
    let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyProperty.self),
    let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEvent.self),
    let getFloat = sym("IOHIDEventGetFloatValue", GetFloatValue.self)
else {
    print("symbols missing")
    exit(1)
}

// kIOHIDEventSystemClientTypeMonitor = 1, kIOHIDEventTypeTemperature = 15
let client = createClient(kCFAllocatorDefault, 1, nil)!.takeRetainedValue()
guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else {
    print("no services")
    exit(1)
}

let field = Int64(15 << 16)
var found: [(String, Double)] = []

for s in services {
    guard let prod = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
    guard let ev = copyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
    let v = getFloat(ev, field)
    if v > 1, v < 150 { found.append((prod, v)) }
}

print("services=\(services.count) sensors=\(found.count)")
for (n, v) in found.sorted(by: { $0.1 > $1.1 }).prefix(12) {
    print(String(format: "%-28s %6.2f", (n as NSString).utf8String!, v))
}
