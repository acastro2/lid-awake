import AppKit
import Foundation
import IOKit

// MARK: - Process helpers

enum Sys {
    static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Reads the live flag from pmset. `pmset -g` needs no root.
    static var sleepDisabled: Bool {
        let (_, text) = run("/usr/bin/pmset", ["-g"])
        for line in text.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
        }
        return false
    }

    static var onAC: Bool {
        run("/usr/bin/pmset", ["-g", "ps"]).1.contains("'AC Power'")
    }

    /// AppleClamshellState from IOKit: Yes when the lid is shut. No root needed.
    static var lidClosed: Bool {
        run("/usr/bin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "1"]).1
            .contains("\"AppleClamshellState\" = Yes")
    }

    /// Passwordless only when a sudoers rule allows it.
    static func setSleepDisabled(_ off: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", off ? "1" : "0"]).0 == 0
    }

    /// Best effort. Returns false when no rule allows it; the flag flip usually sleeps anyway.
    @discardableResult
    static func sleepNow() -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "sleepnow"]).0 == 0
    }
}

// MARK: - Die temperature, private IOHID, no root

final class TempReader {
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloat = @convention(c) (CFTypeRef, Int64) -> Double

    private var services: [(name: String, ref: CFTypeRef)] = []
    private var client: CFTypeRef?
    private var serviceList: CFArray?
    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }

        typealias CreateWithType = @convention(c) (CFAllocator?, Int, CFDictionary?) -> Unmanaged<CFTypeRef>?
        typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

        func sym<T>(_ name: String, _ t: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }

        guard
            let create = sym("IOHIDEventSystemClientCreateWithType", CreateWithType.self),
            let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self),
            let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyProperty.self),
            let ce = sym("IOHIDServiceClientCopyEvent", CopyEvent.self),
            let gf = sym("IOHIDEventGetFloatValue", GetFloat.self)
        else { return }

        copyEvent = ce
        getFloat = gf

        // kIOHIDEventSystemClientTypeMonitor = 1
        guard let raw = create(kCFAllocatorDefault, 1, nil)?.takeRetainedValue(),
              let listRef = copyServices(raw)
        else { return }
        client = raw                       // keep alive: owns the services
        let list = listRef.takeRetainedValue() as CFArray
        serviceList = list                 // keep alive: owns each service

        for case let s as CFTypeRef in (list as NSArray) {
            guard let prod = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String else { continue }
            // PMU tdie* are the CPU die sensors; tcal is a calibration value, not a reading.
            guard prod.hasPrefix("PMU tdie") else { continue }
            services.append((prod, s))
        }
    }

    /// Highest CPU die temperature in °C, or nil when no sensor answered.
    func cpuMax() -> Double? {
        guard let copyEvent, let getFloat else { return nil }
        // kIOHIDEventTypeTemperature = 15, field base = type << 16
        let field = Int64(15 << 16)
        var best = 0.0
        for s in services {
            guard let ev = copyEvent(s.ref, 15, 0, 0)?.takeRetainedValue() else { continue }
            let v = getFloat(ev, field)
            if v > 1, v < 150, v > best { best = v }
        }
        return best > 0 ? best : nil
    }
}

// MARK: - App

final class LidAwake: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let tempLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let powerLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "t")
    private let batteryItem = NSMenuItem(title: "Turn off on battery", action: #selector(toggleBatteryGuard), keyEquivalent: "")
    private let lockItem = NSMenuItem(title: "Lock after 5 min", action: #selector(toggleLock), keyEquivalent: "")
    private var timer: Timer?
    private let temp = TempReader()

    /// Above this, with the lid shut and the flag on, sleep is forced back on.
    private var tripC: Double { UserDefaults.standard.object(forKey: "TripC") as? Double ?? 90 }
    /// The trip stays latched until the die drops below this.
    private var clearC: Double { UserDefaults.standard.object(forKey: "ClearC") as? Double ?? 75 }
    /// Drop the flag as soon as the machine runs on battery.
    private var batteryGuard: Bool { UserDefaults.standard.object(forKey: "BatteryGuard") as? Bool ?? true }
    /// Lock the screen after this much idle, when ticked.
    private var lockAfter5: Bool { UserDefaults.standard.object(forKey: "LockAfter5") as? Bool ?? false }
    private var tripped = false
    private var didLock = false
    private let lockAfter: Double = 300

    func applicationDidFinishLaunching(_ note: Notification) {
        let bar = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = bar

        statusLine.isEnabled = false
        tempLine.isEnabled = false
        powerLine.isEnabled = false
        toggleItem.target = self

        let quit = NSMenuItem(title: "Quit Lid Awake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        batteryItem.target = self
        batteryItem.state = batteryGuard ? .on : .off
        lockItem.target = self
        lockItem.state = lockAfter5 ? .on : .off

        menu.addItem(statusLine)
        menu.addItem(tempLine)
        menu.addItem(powerLine)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(batteryItem)
        menu.addItem(lockItem)
        menu.addItem(.separator())
        menu.addItem(quit)
        bar.menu = menu

        tick()

        let t = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 2
        timer = t
    }

    private func tick() {
        let off = Sys.sleepDisabled
        let lid = Sys.lidClosed
        let ac = Sys.onAC
        let celsius = temp.cpuMax()

        // Thermal guard: only meaningful when the lid is shut and sleep is blocked.
        if off, lid, let c = celsius {
            if c >= tripC {
                _ = Sys.setSleepDisabled(false)
                Sys.sleepNow()
                tripped = true
                NSSound.beep()
                redraw(off: Sys.sleepDisabled, lid: lid, ac: ac, celsius: celsius)
                return
            }
        }
        if tripped, let c = celsius, c < clearC {
            tripped = false
        }

        // Battery guard: the flag ignores the power source, so drop it on battery.
        if batteryGuard, !ac, off {
            _ = Sys.setSleepDisabled(false)
            redraw(off: false, lid: lid, ac: ac, celsius: celsius)
            return
        }

        // Lock guard: 5 minutes without input locks the screen, once per idle period.
        let idle = idleSeconds
        if idle < 60 { didLock = false }
        if lockAfter5, !didLock, idle >= lockAfter {
            lockScreen()
            didLock = true
        }

        redraw(off: off, lid: lid, ac: ac, celsius: celsius)
    }

    private var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Real screen lock through login.framework; display sleep is the fallback.
    private func lockScreen() { LidAwake.lockNow() }

    private typealias LockFunction = @convention(c) () -> Int32
    private static let lockFunction: LockFunction? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_NOW),
              let s = dlsym(h, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(s, to: LockFunction.self)
    }()

    static var lockSymbolFound: Bool { lockFunction != nil }

    static func lockNow() {
        if let lock = lockFunction { _ = lock() }
        else { _ = Sys.run("/usr/bin/pmset", ["displaysleepnow"]) }
    }

    @objc private func toggleLock() {
        UserDefaults.standard.set(!lockAfter5, forKey: "LockAfter5")
        lockItem.state = lockAfter5 ? .on : .off
        didLock = false
        tick()
    }

    @objc private func toggleBatteryGuard() {
        UserDefaults.standard.set(!batteryGuard, forKey: "BatteryGuard")
        batteryItem.state = batteryGuard ? .on : .off
        tick()
    }

    private func redraw(off: Bool, lid: Bool, ac: Bool, celsius: Double?) {
        statusLine.title = tripped ? "Lid awake: OFF (thermal trip)" : (off ? "Lid awake: ON" : "Lid awake: OFF")
        toggleItem.title = off ? "Turn OFF — allow sleep" : "Turn ON — keep awake"

        let tempText: String
        if let c = celsius {
            tempText = String(format: "CPU: %.1f °C", c)
        } else {
            tempText = "CPU: no sensor"
        }
        let lidText = lid ? "lid shut" : "lid open"
        tempLine.attributedTitle = NSAttributedString(
            string: "\(tempText) · \(lidText)",
            attributes: [.font: NSFont.menuFont(ofSize: 11),
                         .foregroundColor: (celsius ?? 0) >= tripC ? NSColor.systemRed : NSColor.secondaryLabelColor])

        batteryItem.state = batteryGuard ? .on : .off
        lockItem.state = lockAfter5 ? .on : .off

        if ac {
            powerLine.attributedTitle = NSAttributedString(
                string: "Power: adapter",
                attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        } else {
            powerLine.attributedTitle = NSAttributedString(
                string: off ? "Power: battery — draining" : "Power: battery",
                attributes: [.font: NSFont.menuFont(ofSize: 11),
                             .foregroundColor: off ? NSColor.systemOrange : NSColor.secondaryLabelColor])
        }

        guard let button = item?.button else { return }
        let symbol = off ? "laptopcomputer" : "moon.zzz.fill"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: off ? "Lid awake on" : "Lid awake off")
        img?.isTemplate = true
        button.image = img
        let t = celsius.map { String(format: "%.0f°C", $0) } ?? "?"
        button.toolTip = off
            ? "Lid awake ON — will not sleep with the lid shut · \(t)"
            : "Lid awake OFF — lid close sleeps the Mac · \(t)"
    }

    @objc private func toggle() {
        guard let nowOn = performToggle() else {
            let alert = NSAlert()
            alert.messageText = "Could not change the sleep setting"
            alert.informativeText = "Lid Awake needs passwordless sudo for these exact commands:\n\n"
                + "Cmnd_Alias LID_AWAKE = /usr/bin/pmset -a disablesleep 1, "
                + "/usr/bin/pmset -a disablesleep 0, /usr/bin/pmset sleepnow\n"
                + "%admin ALL=(ALL) NOPASSWD: LID_AWAKE\n\n"
                + "Install with: sudo visudo -f /etc/sudoers.d/lidawake"
            alert.alertStyle = .warning
            alert.runModal()
            tick()
            return
        }
        if nowOn { tripped = false }
        tick()
    }

    /// Flips the flag. Returns the new state, or nil when sudo refused.
    /// An explicit ON on battery also unticks the battery guard: the click wins.
    func performToggle() -> Bool? {
        let target = !Sys.sleepDisabled
        if target, !Sys.onAC {
            UserDefaults.standard.set(false, forKey: "BatteryGuard")
        }
        guard Sys.setSleepDisabled(target) else { return nil }
        return target
    }
}

// MARK: - Self test, no side effects

if CommandLine.arguments.contains("--selftest") {
    let r = TempReader()
    let c = r.cpuMax()
    print("temp      :", c.map { String(format: "%.2f °C", $0) } ?? "no sensor")
    print("lid closed:", Sys.lidClosed)
    print("on AC     :", Sys.onAC)
    print("flag      :", Sys.sleepDisabled)
    print("trip at   :", UserDefaults.standard.object(forKey: "TripC") as? Double ?? 90)
    print("batt guard:", UserDefaults.standard.object(forKey: "BatteryGuard") as? Bool ?? true)
    let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    print(String(format: "idle      : %.1f s", idle))
    print("lock 5 min:", UserDefaults.standard.object(forKey: "LockAfter5") as? Bool ?? false)
    print("lock fn   :", LidAwake.lockSymbolFound ? "SACLockScreenImmediate" : "missing (falls back to displaysleepnow)")
    exit(0)
}

if CommandLine.arguments.contains("--toggle") {
    let d = LidAwake()
    if let on = d.performToggle() {
        print(on ? "flag=1 (awake)" : "flag=0 (normal sleep)")
        print("battery guard:", UserDefaults.standard.object(forKey: "BatteryGuard") as? Bool ?? true)
    } else {
        print("sudo refused")
    }
    exit(0)
}

if CommandLine.arguments.contains("--locknow") {
    print(LidAwake.lockSymbolFound ? "locking via SACLockScreenImmediate" : "locking via displaysleepnow")
    LidAwake.lockNow()
    exit(0)
}

let app = NSApplication.shared
let delegate = LidAwake()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
