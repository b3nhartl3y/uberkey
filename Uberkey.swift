// Uberkey — Caps Lock becomes the hyper key (⌃⌥⌘ by default).
//
// "Hyper key" is the generic term for one key standing in for several modifiers at once,
// after the Space-cadet keyboard's real Hyper modifier. Nothing here depends on
// hyperkey.app; it is referenced below only to explain where the default chord came from.
//
// How it works, in two halves:
//   1. The physical Caps Lock is remapped to F18 via hidutil, so the OS stops treating it
//      as a lock key. F18 is otherwise unused on Apple keyboards.
//   2. A CGEventTap swallows F18, emits the modifiers as real flagsChanged events, and
//      also stamps them onto keys pressed while it is held. A quick tap with no other key
//      falls through to a configurable action.
//
// Exit codes matter: 0 means "the user quit, stay dead", non-zero means "retry me".
// The launch agent's KeepAlive is SuccessfulExit=false, so it honours both.

import Cocoa
import ApplicationServices
import IOKit
import IOKit.hid
import IOKit.hidsystem

let kHyperKeyCode: Int64 = 79      // F18
let kEscapeKeyCode: CGKeyCode = 53
// A lone press shorter than this counts as a tap rather than a hold. 0.25s was too tight
// to hit deliberately; 1s matches Karabiner's to_if_alone_timeout default.
let kTapTimeout = 1.0
// Which modifiers the hyper key stands for. ⌃⌥⌘ — deliberately NOT ⌃⌥⇧⌘: that is what
// Hyperkey sends (its hyperFlags default is 1835008), so it is what launcher hotkeys on a
// machine that has used Hyperkey are bound to. Adding shift makes it a different chord and
// nothing fires. Configurable from the menu bar.
let kDefaultHyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

enum QuickTapAction: Int {
    case nothing = 0, escape = 1, capsLock = 2

    var label: String {
        switch self {
        case .nothing: return "Nothing"
        case .escape: return "Escape"
        case .capsLock: return "Caps Lock"
        }
    }
}

/// Whether releasing the hyper key should fire the quick-tap action.
/// Pure so it can be asserted below; the one rule that must never break is
/// "hyper was used as a modifier" -> no quick tap, however fast the release.
func shouldFireQuickTap(usedAsModifier: Bool, heldFor: Double) -> Bool {
    !usedAsModifier && heldFor < kTapTimeout
}

// MARK: - The Caps Lock -> F18 remap

/// Owns the hidutil key mapping. This used to be a separate launch agent, which only ran
/// at login; doing it in-process means it can also be re-applied on wake and whenever a
/// keyboard is connected, and undone when the user quits or turns it off.
enum Remap {
    // ponytail: hidutil --set replaces the *whole* user mapping, so this assumes no other
    // remapper (Karabiner, Hyperkey) is running. Fine for one hyper key; revisit if not.
    private static let capsToF18 =
        #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x70000006D}]}"#
    private static let cleared = #"{"UserKeyMapping":[]}"#

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "remap") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "remap"); apply() }
    }

    private static var pending: DispatchWorkItem?

    /// Debounced: connecting one keyboard can fire the watcher several times.
    static func apply() {
        pending?.cancel()
        let work = DispatchWorkItem { set(enabled ? capsToF18 : cleared) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    static func clearNow() {
        pending?.cancel()
        set(cleared)
    }

    private static func set(_ json: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--set", json]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// Shared location for the status file, the log, and the single-instance lock.
func supportDir() -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Uberkey")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private var singleInstanceFD: Int32 = -1

/// Two instances would each install a tap and each emit the modifiers, so one press would
/// send the chord twice and one release would fire twice. flock rather than
/// NSRunningApplication: launchd starts us by executable path, and the lock holds however
/// we were launched. The descriptor is kept open for the process lifetime.
func claimSingleInstance() -> Bool {
    let fd = Darwin.open(supportDir().appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }          // cannot lock; better to run than not
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
    singleInstanceFD = fd
    return true
}

/// Fires when a keyboard appears, so a keyboard plugged in after launch gets remapped too.
/// A C callback cannot capture context, hence the global.
var onKeyboardConnect: (() -> Void)?

final class KeyboardWatcher {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    func start() {
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, _ in
            onKeyboardConnect?()
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

// MARK: - Caps Lock state, since the physical key no longer does it itself

@discardableResult
func toggleCapsLock() -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { return "(no IOHIDSystem service)" }
    defer { IOObjectRelease(service) }

    var connect: io_connect_t = 0
    let opened = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
    guard opened == KERN_SUCCESS else { return "(IOServiceOpen failed: \(opened))" }
    defer { IOServiceClose(connect) }

    var state = false
    IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
    let set = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state)
    return set == KERN_SUCCESS ? "(\(state) -> \(!state))" : "(set failed: \(set))"
}

/// Emits the chosen modifiers as *real* flagsChanged events.
///
/// Stamping the flags onto the next key event is not enough for global hotkeys: Carbon's
/// RegisterEventHotKey (Alfred, Raycast, most launchers) matches against the system's
/// actual modifier state, and no modifier key is physically down. So push the state for
/// real, one modifier at a time with a cumulative flag set, exactly as a keyboard would.
enum HyperModifiers {
    /// Name, virtual keycode, and flag mask for each modifier, in the order a keyboard
    /// would report them. Keycodes: control 0x3B, option 0x3A, shift 0x38, command 0x37.
    static let all: [(name: String, key: CGKeyCode, mask: CGEventFlags)] = [
        ("Control", 0x3B, .maskControl),
        ("Option", 0x3A, .maskAlternate),
        ("Shift", 0x38, .maskShift),
        ("Command", 0x37, .maskCommand),
    ]

    static var flags: CGEventFlags {
        get {
            guard let raw = UserDefaults.standard.object(forKey: "hyperFlags") as? UInt64 else {
                return kDefaultHyperFlags
            }
            return CGEventFlags(rawValue: raw)
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hyperFlags") }
    }

    /// The chosen modifiers with a running total of what is held after each step, so each
    /// posted event reports the same cumulative state a real keyboard would.
    static var steps: [(key: CGKeyCode, flags: CGEventFlags)] {
        var accumulated: CGEventFlags = []
        var out: [(CGKeyCode, CGEventFlags)] = []
        for m in all where flags.contains(m.mask) {
            accumulated.insert(m.mask)
            out.append((m.key, accumulated))
        }
        return out
    }

    private(set) static var isPressed = false

    static func press() {
        for step in steps { post(step.key, step.flags) }
        isPressed = true
    }

    /// Unwinds in reverse, each event carrying what is still held, ending at no flags.
    // ponytail: this resets to no flags rather than to the real hardware state, so tapping
    // hyper while physically holding e.g. shift briefly drops that shift. Rare, and the
    // next physical modifier event corrects it.
    static func release() {
        guard isPressed else { return }
        isPressed = false
        let seq = steps
        for i in stride(from: seq.count - 1, through: 0, by: -1) {
            post(seq[i].key, i > 0 ? seq[i - 1].flags : [])
        }
    }

    private static func post(_ key: CGKeyCode, _ flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                              virtualKey: key, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

func tapKey(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
}

// MARK: - The tap

final class Uberkey {
    static let shared = Uberkey()

    var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
    }
    // NB: integer(forKey:) returns 0 for an unset key, and 0 is .nothing — so the default
    // has to come from an object(forKey:) check, not from the raw integer.
    var quickTap = QuickTapAction(
        rawValue: UserDefaults.standard.object(forKey: "quickTap") as? Int ?? QuickTapAction.escape.rawValue
    ) ?? .escape {
        didSet { UserDefaults.standard.set(quickTap.rawValue, forKey: "quickTap") }
    }

    private var tap: CFMachPort?
    var isRunning: Bool { tap != nil }

    /// Called whenever the key goes down or up, so the menu bar icon can reflect it.
    var onHeldChange: ((Bool) -> Void)?

    private(set) var held = false
    private var heldSince = 0.0
    private var usedAsModifier = false


    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in
                Uberkey.shared.handle(type: type, event: event)
            },
            userInfo: nil
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Drops the modifiers immediately, for when the key-up will never arrive — the machine
    /// is going to sleep, or the screen locked mid-hold.
    func forceRelease(_ why: String) {
        guard held || HyperModifiers.isPressed else { return }
        log("force release (\(why))")
        held = false
        HyperModifiers.release()
        onHeldChange?(false)
    }

    /// If the key-up is ever missed the modifiers would stay stuck down, which makes the
    /// whole machine feel broken. Release them unconditionally after a plausible hold.
    private func armStuckModifierWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if held {
                log("stuck modifier watchdog fired")
                held = false
                HyperModifiers.release()
            }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that blocks for too long; just switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard enabled else { return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if code == kHyperKeyCode && (type == .keyDown || type == .keyUp) {
            if type == .keyDown {
                if !held {                       // ignore auto-repeat
                    held = true
                    heldSince = CFAbsoluteTimeGetCurrent()
                    usedAsModifier = false
                    HyperModifiers.press()
                    log("hyper down")
                    onHeldChange?(true)
                    armStuckModifierWatchdog()
                }
            } else {
                held = false
                HyperModifiers.release()     // before any synthesised key, not after
                onHeldChange?(false)
                let heldFor = CFAbsoluteTimeGetCurrent() - heldSince
                if shouldFireQuickTap(usedAsModifier: usedAsModifier, heldFor: heldFor) {
                    switch quickTap {
                    case .escape: tapKey(kEscapeKeyCode); log("quick tap -> escape")
                    case .capsLock: log("quick tap -> caps lock \(toggleCapsLock())")
                    case .nothing: log("quick tap -> nothing (configured)")
                    }
                } else {
                    log(String(format: "hyper up after %.2fs, usedAsModifier=%@",
                               heldFor, usedAsModifier ? "yes" : "no"))
                }
            }
            return nil                            // F18 never reaches any app
        }

        if held, type == .keyDown || type == .keyUp {
            if !usedAsModifier { log("stamping hyper flags onto a keypress") }
            usedAsModifier = true
            event.flags.formUnion(HyperModifiers.flags)
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Menu bar

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let keyboards = KeyboardWatcher()

    func applicationDidFinishLaunching(_ note: Notification) {
        guard claimSingleInstance() else {
            log("another instance holds the lock — exiting")
            exit(0)         // clean exit: KeepAlive is SuccessfulExit=false, so we stay dead
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        Uberkey.shared.onHeldChange = { [weak self] _ in self?.updateIcon() }
        buildMenu()
        watchForSleepAndLock()

        Remap.apply()
        onKeyboardConnect = { Remap.apply() }
        keyboards.start()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in Remap.apply() }

        log("started — hyper flags \(HyperModifiers.flags.rawValue), quick tap \(Uberkey.shared.quickTap)")
        attemptStart()
    }

    /// Leaving the remap in place with nothing listening would make Caps Lock dead, so
    /// hand it back on the way out.
    func applicationWillTerminate(_ note: Notification) {
        HyperModifiers.release()
        Remap.clearNow()
    }

    /// AXIsProcessTrusted() caches its result for the lifetime of the process, and so does
    /// the tap's permission check — a process that started before the grant can never see
    /// it. So retrying means retrying in a *new* process: prompt once (the flag is
    /// persisted so the dialog cannot repeat), then exit non-zero for launchd to respawn.
    private func attemptStart() {
        if Uberkey.shared.start() {
            writeStatus("live")
            buildMenu()
            return
        }
        writeStatus("waiting-for-accessibility")
        buildMenu()

        if !UserDefaults.standard.bool(forKey: "didPrompt") {
            UserDefaults.standard.set(true, forKey: "didPrompt")
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.retryInFreshProcess() }
    }

    /// Exits non-zero so the launch agent's KeepAlive respawns us. Deliberately does not
    /// spawn a replacement itself: detecting "am I under launchd" is unreliable, and
    /// guessing wrong left orphan processes that launchd did not manage.
    private func retryInFreshProcess() {
        log("exiting to retry in a fresh process")
        exit(1)
    }

    /// Lets the install script confirm the tap is actually running.
    private func writeStatus(_ s: String) {
        try? s.write(to: supportDir().appendingPathComponent("status"), atomically: true, encoding: .utf8)
    }

    /// Outline when idle, filled while the key is held, badged when access is missing.
    /// The held state is the cheapest possible confirmation that the key is working.
    private func updateIcon() {
        let symbol: String
        if !Uberkey.shared.isRunning {
            symbol = "capslock.trianglebadge.exclamationmark"
        } else {
            symbol = Uberkey.shared.held ? "capslock.fill" : "capslock"
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Uberkey")
    }

    /// A key-up never arrives if the Mac sleeps or the screen locks mid-hold, which would
    /// leave the modifiers logically down until the watchdog catches it.
    private func watchForSleepAndLock() {
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                log("system event: \(name.rawValue)")
                Uberkey.shared.forceRelease(name.rawValue)
            }
        }
        // Screen lock is not an NSWorkspace notification.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            log("system event: com.apple.screenIsLocked")
            Uberkey.shared.forceRelease("screenIsLocked")
        }
    }

    private func buildMenu() {
        let live = Uberkey.shared.isRunning
        updateIcon()

        let menu = NSMenu()
        if live {
            add(menu, Uberkey.shared.enabled ? "Uber Key: On" : "Uber Key: Off", #selector(toggleEnabled))
        } else {
            let waiting = NSMenuItem(title: "Waiting for Accessibility access…", action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            menu.addItem(waiting)
            add(menu, "Open Privacy & Security…", #selector(openSettings))
        }

        menu.addItem(.separator())
        header(menu, "Quick tap sends")
        for action in [QuickTapAction.escape, .capsLock, .nothing] {
            let mi = add(menu, action.label, #selector(setQuickTap(_:)))
            mi.tag = action.rawValue
            mi.state = Uberkey.shared.quickTap == action ? .on : .off
        }

        menu.addItem(.separator())
        header(menu, "Uber key sends")
        for m in HyperModifiers.all {
            let mi = add(menu, m.name, #selector(toggleHyperFlag(_:)))
            mi.tag = Int(m.mask.rawValue)
            mi.state = HyperModifiers.flags.contains(m.mask) ? .on : .off
        }

        menu.addItem(.separator())
        header(menu, "Keyboard")
        let remap = add(menu, "Remap Caps Lock to Uber Key", #selector(toggleRemap))
        remap.state = Remap.enabled ? .on : .off
        remap.toolTip = Remap.enabled
            ? "Off restores Caps Lock to its normal behaviour."
            : "Caps Lock is currently a normal Caps Lock; the Uber key is unavailable."

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Uberkey", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let mi = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func header(_ menu: NSMenu, _ title: String) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    @objc private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleEnabled() {
        Uberkey.shared.enabled.toggle()
        buildMenu()
    }

    @objc private func toggleHyperFlag(_ sender: NSMenuItem) {
        let mask = CGEventFlags(rawValue: UInt64(sender.tag))
        var flags = HyperModifiers.flags
        if flags.contains(mask) { flags.subtract(mask) } else { flags.insert(mask) }
        HyperModifiers.flags = flags
        log("hyper flags now \(flags.rawValue)")
        buildMenu()
    }

    @objc private func toggleRemap() {
        Remap.enabled.toggle()
        buildMenu()
    }

    @objc private func setQuickTap(_ sender: NSMenuItem) {
        Uberkey.shared.quickTap = QuickTapAction(rawValue: sender.tag) ?? .escape
        buildMenu()
    }

    /// exit(0) so the launch agent's SuccessfulExit=false KeepAlive leaves us dead.
    @objc private func quit() {
        Remap.clearNow()
        exit(0)
    }
}

/// Silent unless switched on:
///     defaults write agency.honcho.uberkey log -bool true
/// Kept rather than deleted because it is what diagnosed the hyper key end to end. When
/// enabled it appends to ~/Library/Application Support/Uberkey/log, and records only the
/// hyper key's own events — never the identity of any other key pressed, which would make
/// this a keylogger. Read per call so it can be toggled without a restart.
func log(_ msg: String) {
    guard UserDefaults.standard.bool(forKey: "log") else { return }
    let dir = supportDir()
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    let url = dir.appendingPathComponent("log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

func selfTest() {
    // Absolute bound as well as the relative checks below: expressing everything in terms
    // of kTapTimeout makes the assertions vacuous if the constant itself goes wrong.
    assert(kTapTimeout > 0.1 && kTapTimeout <= 2.0, "kTapTimeout outside a usable range")
    // 1835008 = control+option+command, the value Hyperkey uses and therefore the value
    // existing launcher hotkeys are bound to. Adding shift silently breaks every one.
    assert(kDefaultHyperFlags.rawValue == 1835008, "default hyper flags must match Hyperkey's")
    assert(shouldFireQuickTap(usedAsModifier: false, heldFor: 0.05))
    assert(!shouldFireQuickTap(usedAsModifier: true, heldFor: 0.05), "hyper+key must never send the quick-tap key")
    assert(!shouldFireQuickTap(usedAsModifier: true, heldFor: 0.0))
    assert(!shouldFireQuickTap(usedAsModifier: false, heldFor: kTapTimeout + 0.5), "a long hold is not a tap")
    print("selftest ok")
}


// MARK: - Diagnostics

/// Runs a command and returns its trimmed output. stderr is merged in, because both
/// codesign and spctl report on stderr rather than stdout. Used only by --doctor.
func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func describe(_ flags: CGEventFlags) -> String {
    let glyphs = [("⌃", CGEventFlags.maskControl), ("⌥", .maskAlternate),
                  ("⇧", .maskShift), ("⌘", .maskCommand)]
    let set = glyphs.filter { flags.contains($0.1) }.map(\.0).joined()
    return set.isEmpty ? "none" : "\(set)  (\(flags.rawValue))"
}

/// One command that answers every question a debugging session starts with. Exits non-zero
/// if anything looks wrong, so it can be used as a check rather than only read.
func doctor() -> Never {
    var problems: [String] = []
    func row(_ label: String, _ value: String) {
        print("  \(label.padding(toLength: 13, withPad: " ", startingAt: 0))\(value)")
    }

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    print("Uberkey doctor")
    row("bundle", "\(Bundle.main.bundlePath)  (v\(version))")

    // The lock is the cleanest liveness test: if we can take it, nobody else holds it.
    let running = !claimSingleInstance()
    row("instance", running ? "running" : "NOT running")
    if !running { problems.append("no instance is running") }

    let status = (try? String(contentsOf: supportDir().appendingPathComponent("status"),
                              encoding: .utf8)) ?? "(no status file)"
    row("tap", status)
    if status != "live" { problems.append("tap is not live: \(status)") }

    // Caps Lock is HID usage 0x700000039; F18 is 0x70000006D.
    let mapping = shell("/usr/bin/hidutil", ["property", "--get", "UserKeyMapping"])
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined()
    let mapped = mapping.contains("30064771129") && mapping.contains("30064771181")
    row("key mapping", mapped ? "Caps Lock -> F18" : "none  \(mapping.isEmpty ? "(unreadable)" : mapping)")
    if !mapped && Remap.enabled { problems.append("remap is enabled but not applied") }

    row("uber key", describe(HyperModifiers.flags))
    let quick = QuickTapAction(rawValue: UserDefaults.standard.object(forKey: "quickTap") as? Int
                               ?? QuickTapAction.escape.rawValue) ?? .escape
    row("quick tap", quick.label)
    row("remap", Remap.enabled ? "on" : "off")
    row("logging", UserDefaults.standard.bool(forKey: "log") ? "on" : "off")

    let uid = String(getuid())
    let agent = shell("/bin/launchctl", ["print", "gui/\(uid)/agency.honcho.uberkey"])
    if agent.isEmpty {
        row("agent", "NOT loaded")
        problems.append("launch agent is not loaded — run ./install.sh")
    } else {
        let pid = agent.split(separator: "\n").first { $0.contains("pid = ") }?
            .trimmingCharacters(in: .whitespaces) ?? "loaded"
        row("agent", "loaded, \(pid)")
    }

    let sig = shell("/usr/bin/codesign", ["-dvv", Bundle.main.bundlePath])
    row("signed by", sig.split(separator: "\n").first { $0.hasPrefix("Authority=") }?
        .replacingOccurrences(of: "Authority=", with: "") ?? "unsigned")
    // Expected to be rejected for a self-signed build; launchd starts us by path anyway.
    let gk = shell("/usr/sbin/spctl", ["-a", "-t", "exec", Bundle.main.bundlePath])
    row("gatekeeper", gk.contains("rejected")
        ? "rejected — expected for a self-signed build, does not affect launchd"
        : (gk.isEmpty ? "accepted" : gk))

    print("")
    if problems.isEmpty {
        print("All good.")
        exit(0)
    }
    print("Problems:")
    for p in problems { print("  - \(p)") }
    exit(1)
}

if CommandLine.arguments.contains("--doctor") {
    doctor()
}

if CommandLine.arguments.contains("--selftest") {
    selfTest()
    exit(0)
}


let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
