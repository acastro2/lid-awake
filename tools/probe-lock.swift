import Foundation
import CoreGraphics

let paths = [
    "/System/Library/PrivateFrameworks/login.framework/Versions/A/login",
    "/System/Library/PrivateFrameworks/login.framework/login",
]
for p in paths {
    if let h = dlopen(p, RTLD_NOW) {
        print("opened", p)
        if let s = dlsym(h, "SACLockScreenImmediate") {
            print("  SACLockScreenImmediate found at", s)
        } else { print("  symbol missing") }
    } else {
        print("failed", p, String(cString: dlerror()))
    }
}

// Idle time without any permission
let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
print(String(format: "idle seconds: %.1f", idle))
