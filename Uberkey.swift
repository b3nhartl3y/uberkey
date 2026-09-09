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
import ServiceManagement
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
    private var mouseSamples = 0
    private var loggedStampThisHold = false


    func start() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.mouseMoved.rawValue)
                 | (1 << CGEventType.leftMouseDragged.rawValue)
                 | (1 << CGEventType.rightMouseDragged.rawValue)
                 | (1 << CGEventType.otherMouseDragged.rawValue)
                 | (1 << CGEventType.scrollWheel.rawValue)

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
        WindowCycler.shared.cancel()
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
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            // The tap gets switched off if it dawdles; anything this slow is a warning sign.
            if ms > 20 { log(String(format: "SLOW handler: %.0fms on %d", ms, type.rawValue)) }
        }
        return handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that blocks for too long; just switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Keystrokes are delivered unmodified while the tap is off, so this is exactly
            // what a chord silently failing to fire looks like.
            log("TAP DISABLED (\(type == .tapDisabledByTimeout ? "timeout" : "user input")) — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard enabled else { return Unmanaged.passUnretained(event) }

        switch type {
        case .scrollWheel:
            // On a trackpad or Magic Mouse a "swipe" is fingers on the surface, which is a
            // scroll: the pointer does not move at all. Measured at 1px of pointer travel
            // for a full swipe, which is why watching pointer movement alone saw nothing.
            guard held else { return Unmanaged.passUnretained(event) }
            let sy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let sx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            if mouseSamples < 5 {
                mouseSamples += 1
                log(String(format: "cycle: scroll axis1=%.1f axis2=%.1f", sy, sx))
            }
            // Negated so fingers moving down reads as downward travel, matching the pointer
            // path where positive Y is down.
            _ = WindowCycler.shared.scrub(dx: -sx, dy: -sy)
            usedAsModifier = true
            return nil          // never let the page underneath scroll as well

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard held else { return Unmanaged.passUnretained(event) }
            if mouseSamples < 5 {
                mouseSamples += 1
                let dx = event.getDoubleValueField(.mouseEventDeltaX)
                let dy = event.getDoubleValueField(.mouseEventDeltaY)
                let p = event.location
                log(String(format: "cycle: move dx=%.1f dy=%.1f at (%.0f,%.0f)", dx, dy, p.x, p.y))
            }
            guard WindowCycler.shared.scrub(dx: event.getDoubleValueField(.mouseEventDeltaX),
                                            dy: event.getDoubleValueField(.mouseEventDeltaY))
            else { return Unmanaged.passUnretained(event) }
            usedAsModifier = true       // a swipe is not a quick tap
            return nil                 // hold the pointer still while scrubbing
        default:
            break
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if code == kHyperKeyCode && (type == .keyDown || type == .keyUp) {
            if type == .keyDown {
                if !held {                       // ignore auto-repeat
                    held = true
                    heldSince = CFAbsoluteTimeGetCurrent()
                    usedAsModifier = false
                    mouseSamples = 0
                    loggedStampThisHold = false
                    HyperModifiers.press()
                    log("hyper down")
                    onHeldChange?(true)
                    armStuckModifierWatchdog()
                }
            } else {
                held = false
                HyperModifiers.release()     // before any synthesised key, not after
                onHeldChange?(false)
                WindowCycler.shared.endHold()
                let heldFor = CFAbsoluteTimeGetCurrent() - heldSince
                if shouldFireQuickTap(usedAsModifier: usedAsModifier, heldFor: heldFor) {
                    // async: measured at 30ms inline, all of it spent inside the tap
                    // callback. macOS switches off a tap that responds too slowly, and
                    // while it is off keystrokes pass through unmodified — which is what a
                    // chord silently failing to fire looks like.
                    let action = quickTap
                    DispatchQueue.main.async {
                        switch action {
                        case .escape: tapKey(kEscapeKeyCode); log("quick tap -> escape")
                        case .capsLock: log("quick tap -> caps lock \(toggleCapsLock())")
                        case .nothing: log("quick tap -> nothing (configured)")
                        }
                    }
                } else {
                    log(String(format: "hyper up after %.2fs, usedAsModifier=%@",
                               heldFor, usedAsModifier ? "yes" : "no"))
                }
            }
            return nil                            // F18 never reaches any app
        }

        if held, type == .keyDown || type == .keyUp {
            usedAsModifier = true
            event.flags.formUnion(HyperModifiers.flags)
            // Caps Lock is not part of the chord. If it happens to be on — easy to do when
            // the quick tap is set to Caps Lock — its AlphaShift flag rides along and makes
            // this a different chord, so registered hotkeys stop matching.
            event.flags.subtract(.maskAlphaShift)
            if !loggedStampThisHold {
                loggedStampThisHold = true
                log("stamping onto keypress: flags=\(event.flags.rawValue) "
                    + "(want \(HyperModifiers.flags.rawValue))")
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Menu bar

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let keyboards = KeyboardWatcher()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        guard claimSingleInstance() else {
            log("another instance holds the lock — exiting")
            exit(0)         // clean exit: KeepAlive is SuccessfulExit=false, so we stay dead
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        Uberkey.shared.onHeldChange = { [weak self] _ in self?.updateIcon() }
        buildMenu()
        watchForSleepAndLock()
        watchForTermination()
        ensureLoginItem()

        Updater.onStateChange = { [weak self] in self?.buildMenu() }
        Updater.check(userAsked: false)
        // Once a day is plenty for a utility like this, and stays well inside GitHub's
        // unauthenticated rate limit.
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in
            Updater.check(userAsked: false)
        }
        WindowCycler.shared.start()

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

    /// Downloaded copies have no launch agent — nobody ran install.sh — so register as a
    /// login item on first run. Installed-from-source copies are started by launchd and
    /// skip this, so the two never both start a copy. (The flock would stop them anyway.)
    private func ensureLoginItem() {
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/agency.honcho.uberkey.plist")
        guard !FileManager.default.fileExists(atPath: agent.path) else { return }
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            log("registered as a login item")
        } catch {
            log("could not register as a login item: \(error.localizedDescription)")
        }
    }

    /// A signal-based kill bypasses applicationWillTerminate, so the modifiers would be
    /// left logically held with no process alive to release them — which quietly breaks
    /// anything that requires no modifier, hot corners included. SIGKILL cannot be caught;
    /// everything else can.
    ///
    /// Deliberately does NOT clear the key remap. A SIGTERM is usually a restart
    /// (`launchctl kickstart -k`), and clearing it here would race the incoming instance
    /// that has just applied it. A real removal goes through the menu's Quit or
    /// `install.sh --uninstall`, both of which clear it explicitly.
    private func watchForTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)        // stop the default action killing us first
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                log("signal \(sig) — releasing modifiers, exiting")
                Uberkey.shared.forceRelease("signal \(sig)")
                usleep(50_000)          // let the posted events land before we go
                // Non-zero, so KeepAlive brings us back: a keyboard tool that stays dead
                // after a stray kill is worse than one that returns. A deliberate stop is
                // the menu's Quit (exit 0) or install.sh --uninstall (which boots the job
                // out entirely, where KeepAlive no longer applies).
                exit(1)
            }
            src.resume()
            signalSources.append(src)
        }
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
        header(menu, "Updates")
        let now = add(menu, Updater.availableVersion.map { "Update now — \($0) available" }
                              ?? "Update now", #selector(updateNow))
        now.toolTip = "Checks GitHub and installs a newer version if there is one."
        let status = NSMenuItem(title: "  \(Updater.lastResult)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let auto = add(menu, "Update automatically", #selector(toggleAutoUpdate))
        auto.state = Updater.automatic ? .on : .off
        auto.isEnabled = !Updater.managedBySource
        if Updater.managedBySource {
            auto.toolTip = "This copy was built by install.sh; update it with git pull && ./install.sh"
        }

        menu.addItem(.separator())
        header(menu, "Hold Uber and sweep the mouse")
        let win = add(menu, "Sideways: switch windows", #selector(toggleWindowSweep))
        win.state = WindowCycler.windowSweepEnabled ? .on : .off
        let rev = add(menu, "Reverse sweep direction", #selector(toggleReverseSweep))
        rev.state = WindowCycler.reverseSweep ? .on : .off

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

    @objc private func toggleWindowSweep() {
        WindowCycler.windowSweepEnabled.toggle()
        buildMenu()
    }

    @objc private func toggleReverseSweep() {
        WindowCycler.reverseSweep.toggle()
        buildMenu()
    }

    /// One action: look, and install if there is something newer.
    @objc private func updateNow() {
        Updater.check(userAsked: true, thenInstall: true)
        buildMenu()
    }

    @objc private func toggleAutoUpdate() {
        Updater.automatic.toggle()
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
func log(_ msg: @autoclosure () -> String) {
    // @autoclosure matters: several call sites interpolate an Accessibility call, and Swift
    // evaluates arguments eagerly. Without this, `record()` made an AX round trip on every
    // app switch even with logging off — on the same thread as the event tap.
    guard UserDefaults.standard.bool(forKey: "log") else { return }
    let dir = supportDir()
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg())\n"
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

    // Version comparison decides whether an update installs itself, so it is worth pinning.
    assert(Updater.isNewer("1.1", than: "1.0"))
    assert(Updater.isNewer("1.10", than: "1.9"), "compare numerically, not as text")
    assert(Updater.isNewer("1.0.1", than: "1.0"))
    assert(!Updater.isNewer("1.0", than: "1.0"), "same version is not an update")
    assert(!Updater.isNewer("0.9", than: "1.0"), "must never install an older build")
    assert(shouldFireQuickTap(usedAsModifier: false, heldFor: 0.05))
    assert(!shouldFireQuickTap(usedAsModifier: true, heldFor: 0.05), "hyper+key must never send the quick-tap key")
    assert(!shouldFireQuickTap(usedAsModifier: true, heldFor: 0.0))
    assert(!shouldFireQuickTap(usedAsModifier: false, heldFor: kTapTimeout + 0.5), "a long hold is not a tap")
    print("selftest ok")
}



// MARK: - Window cycling

/// AXObserver callbacks are C function pointers and cannot capture, hence the free function.
private func axFocusChanged(_ observer: AXObserver, _ element: AXUIElement,
                            _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    WindowCycler.shared.noteFocusChange(element)
}

func axTitle(_ element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success
    else { return nil }        // a closed window fails here, which is how dead entries are pruned
    return (value as? String) ?? ""
}

func axSubrole(_ element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success
    else { return nil }
    return value as? String
}

func axRole(_ element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    else { return nil }
    return value as? String
}

func axWindowList(pid: pid_t) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                        kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return [] }
    return windows
}

func axFocusedWindow(pid: pid_t) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                        kAXFocusedWindowAttribute as CFString, &value) == .success,
          let raw = value else { return nil }
    return (raw as! AXUIElement)
}

/// Hold the Uber key and swipe the mouse sideways to move through the windows you have
/// actually been in. Each step brings its window straight to the front — there is no
/// overlay and nothing to confirm; the windows themselves are the feedback.
///
/// The list is our own most-recently-used history rather than the window stacking order,
/// because "the window I was in before" is not "the window behind this one" once you have
/// used more than two.
final class WindowCycler {
    static let shared = WindowCycler()

    /// Kept short on purpose: this is for hopping between the few windows you are working
    /// across, not for browsing everything open.
    static let historyLimit = 5
    private static let pixelsPerStep = 100.0
    /// Raising is rate-limited so a fast swipe does not strobe through windows. The final
    /// position is always raised, so the limit smooths the journey without changing where
    /// you land.
    private static let minRaiseInterval = 0.15
    /// How long the pointer must be still before another sweep counts. Without this, one
    /// continuous sweep kept stepping — 23 raises in 9 seconds, thrashing across the list.
    private static let rearmPause = 0.15

    private struct Entry {
        let pid: pid_t
        let element: AXUIElement
    }

    /// Sideways sweep cycles windows.
    static var windowSweepEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sweepWindows") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sweepWindows") }
    }
    /// Natural-scrolling settings and device conventions make the sign genuinely
    /// unpredictable, so this is a setting rather than something to guess at and rebuild.
    static var reverseSweep: Bool {
        get { UserDefaults.standard.bool(forKey: "reverseSweep") }
        set { UserDefaults.standard.set(newValue, forKey: "reverseSweep") }
    }

    private var history: [Entry] = []
    private var observers: [pid_t: AXObserver] = [:]

    private var scrubbing = false
    private var travelX = 0.0
    private var travelY = 0.0
    /// Diagnostic only: total distance swept during one hold, never reset by a step, so the
    /// log can say how far the pointer actually went rather than how far it went recently.
    private var totalX = 0.0
    private var totalY = 0.0

    /// Persists between swipes, which is what makes this back-and-forward: swipe one way to
    /// step through the list, the other way to come back. Reset only when you change
    /// windows by some other means.
    private var index = 0

    private var lastRaise = 0.0
    private var pendingRaise: DispatchWorkItem?

    /// One sweep moves one window. After a step this disarms, and re-arms either when the
    /// pointer goes still or the moment you sweep the other way — so flicking back and
    /// forth between two windows stays instant.
    private var armed = true
    private var lastStepDir = 0
    private var rearmWork: DispatchWorkItem?
    /// What we raised, and when — so the focus notification caused by our own raise is not
    /// mistaken for the user switching windows themselves.
    private var raisedElement: AXUIElement?
    private var raisedAt = 0.0

    /// The lock screen activates loginwindow, which would otherwise be recorded as a window
    /// worth cycling to — seen happening in practice.
    private var screenLocked = false
    /// Snapshot taken when the swipe starts. Raising as you go would otherwise rearrange
    /// the very list being navigated, so the order is frozen for the duration.
    private var candidates: [Entry] = []

    // MARK: History

    func start() {
        let centre = NSWorkspace.shared.notificationCenter
        centre.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.observe(app)
            if let window = axFocusedWindow(pid: app.processIdentifier) {
                self?.record(pid: app.processIdentifier, element: window)
            }
        }
        centre.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.observe(app)
            }
        }
        centre.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.forget(pid: app.processIdentifier)
            }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
        }
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                                object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
        }

        for app in NSWorkspace.shared.runningApplications { observe(app) }
        // Seed with the current window, so the very first swipe has somewhere to go.
        if let front = NSWorkspace.shared.frontmostApplication,
           let window = axFocusedWindow(pid: front.processIdentifier) {
            record(pid: front.processIdentifier, element: window)
        }
        seedHistory()
    }

    /// The history is in memory only, so a restart would otherwise leave nothing to cycle
    /// through until the user had switched windows several times — which reads as the
    /// feature being broken. Fill it from what is already open, frontmost app first. Real
    /// usage order takes over as soon as windows are actually used.
    private func seedHistory() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
                && !Self.notCycleTargets.contains($0.bundleIdentifier ?? "")
        }
        if let front, let i = apps.firstIndex(where: { $0.processIdentifier == front }) {
            apps.insert(apps.remove(at: i), at: 0)
        }
        for app in apps {
            for window in axWindowList(pid: app.processIdentifier) {
                guard history.count < Self.historyLimit else {
                    log("cycle: seeded \(history.count) windows")
                    return
                }
                guard axTitle(window) != nil,
                      axSubrole(window) == (kAXStandardWindowSubrole as String),
                      !history.contains(where: { CFEqual($0.element, window) }) else { continue }
                history.append(Entry(pid: app.processIdentifier, element: window))
            }
        }
        log("cycle: seeded \(history.count) windows")
    }

    /// Watches for window focus moving *within* an app, which app activation alone misses —
    /// switching between two Chrome windows is exactly the case this feature is for.
    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, observers[pid] == nil, pid != getpid() else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, axFocusChanged, &observer) == .success,
              let observer else { return }
        AXObserverAddNotification(observer, AXUIElementCreateApplication(pid),
                                  kAXFocusedWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func forget(pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        history.removeAll { $0.pid == pid }
    }

    /// The notification carries the window, but some apps send the application element, so
    /// resolve either into a window.
    func noteFocusChange(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if axRole(element) == kAXWindowRole {
            record(pid: pid, element: element)
        } else if let window = axFocusedWindow(pid: pid) {
            record(pid: pid, element: window)
        }
    }

    /// Processes that own windows but are never somewhere you want to switch *to*.
    private static let notCycleTargets: Set<String> = [
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine",
        "com.apple.controlcenter", "com.apple.notificationcenterui",
    ]

    func record(pid: pid_t, element: AXUIElement) {
        guard !screenLocked else { return }
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           Self.notCycleTargets.contains(bundle) { return }
        // Only ordinary windows. Permission prompts, onboarding panels, sheets and
        // popovers were all getting in and eating slots out of the five — seen in the log
        // as StageManagerOnboarding and universalAccessAuthWarn. A denylist of process
        // names would never keep up; the window's own subrole is the durable test.
        guard axSubrole(element) == (kAXStandardWindowSubrole as String) else { return }
        // Our own raising fires these notifications too; ignoring them mid-swipe is what
        // keeps the snapshot stable.
        guard !scrubbing else { return }
        // Our own raise fires this too, just after the swipe ends. Treating that as a user
        // switch would reorder the list and throw away the cursor.
        if let raised = raisedElement, CFEqual(raised, element),
           CFAbsoluteTimeGetCurrent() - raisedAt < 1.0 { return }
        // App activation and the focus observer both fire for one switch; ignore the repeat.
        if let first = history.first, CFEqual(first.element, element) { return }
        history.removeAll { CFEqual($0.element, element) }
        history.insert(Entry(pid: pid, element: element), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        index = 0          // a deliberate switch makes this the new starting point
        log("cycle: recorded \(name(pid)) — \(axTitle(element) ?? "?")   (history \(history.count))")
    }

    private func name(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    }

    // MARK: Swiping

    /// Returns true once a swipe is under way, which tells the tap to swallow the movement
    /// so the pointer holds still and no app sees a stray drag.
    func scrub(dx: Double, dy: Double) -> Bool {
        if !armed {
            // Sweeping back is a new gesture, not a continuation of the last one.
            let reversed = (dx != 0 && (dx > 0 ? 1 : -1) != lastStepDir && lastStepAxis == .horizontal)
                || (dy != 0 && (dy > 0 ? 1 : -1) != lastStepDir && lastStepAxis == .vertical)
            if lastStepDir != 0, reversed {
                armed = true
                travelX = 0
                travelY = 0
            } else {
                // No movement means no events, so stillness has to be a timer.
                scheduleRearm()
            }
        }

        travelX += dx
        travelY += dy
        totalX += dx
        totalY += dy

        if !scrubbing {
            guard max(abs(travelX), abs(travelY)) >= Self.pixelsPerStep else { return false }
            beginScrub()
        }
        guard armed else { return true }

        // Whichever axis has travelled furthest wins, so a diagonal sweep does one thing
        // rather than both. One step per sweep, then disarm.
        // Sideways only. Vertical is deliberately ignored: it keeps ordinary vertical
        // scrolling from triggering anything, and macOS already switches Spaces on a
        // horizontal swipe of its own, so there is nothing worth putting on the other axis.
        guard abs(travelX) >= Self.pixelsPerStep, abs(travelX) >= abs(travelY) else { return true }
        var direction = travelX > 0 ? 1 : -1
        if Self.reverseSweep { direction = -direction }
        takeStep(axis: .horizontal, direction: direction)
        guard Self.windowSweepEnabled else { return true }
        let wanted = max(0, min(candidates.count - 1, index + direction))
        if wanted != index {
            index = wanted
            requestRaise()
        }
        return true
    }

    private enum Axis { case none, horizontal, vertical }
    private var lastStepAxis = Axis.none

    private func takeStep(axis: Axis, direction: Int) {
        travelX = 0
        travelY = 0
        armed = false
        lastStepDir = direction
        lastStepAxis = axis
        scheduleRearm()
    }

    /// Debounced: every further movement pushes the deadline out, so a long sweep re-arms
    /// only once it actually ends.
    private func scheduleRearm() {
        rearmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.armed = true
            self?.travelX = 0
            self?.travelY = 0
        }
        rearmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rearmPause, execute: work)
    }

    private func beginScrub() {
        // Deliberately no Accessibility calls here — this runs inside the tap callback.
        // Closed windows are pruned when a raise fails instead of by checking up front.
        candidates = history
        index = min(index, max(0, candidates.count - 1))   // keep the cursor, clamp it
        scrubbing = true
        log("cycle: begin, \(candidates.count) windows")
    }

    /// Coalesces rapid steps into at most one raise per interval, always ending on the
    /// current position.
    private func requestRaise() {
        pendingRaise?.cancel()
        let wait = Self.minRaiseInterval - (CFAbsoluteTimeGetCurrent() - lastRaise)
        guard wait > 0 else {
            // async, never inline: this is called from inside the event tap callback, and
            // raising a window is a synchronous message to another app that can block for
            // hundreds of milliseconds. A slow tap gets switched off by macOS, which drops
            // keystrokes — the likely cause of chords intermittently not firing.
            DispatchQueue.main.async { [weak self] in self?.performRaise() }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.performRaise() }
        pendingRaise = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func performRaise() {
        pendingRaise = nil
        lastRaise = CFAbsoluteTimeGetCurrent()
        guard index >= 0, index < candidates.count else { return }
        raise(candidates[index])
    }

    private func raise(_ entry: Entry) {
        raisedElement = entry.element
        raisedAt = CFAbsoluteTimeGetCurrent()
        let raised = AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString)
        if raised == .invalidUIElement {        // window has since closed
            history.removeAll { CFEqual($0.element, entry.element) }
            candidates.removeAll { CFEqual($0.element, entry.element) }
            index = min(index, max(0, candidates.count - 1))
            log("cycle: dropped a closed window")
            return
        }
        let setMain = AXUIElementSetAttributeValue(entry.element, kAXMainAttribute as CFString,
                                                   true as CFTypeRef)
        let activated = NSRunningApplication(processIdentifier: entry.pid)?.activate() ?? false
        log("cycle: [\(index)] \(name(entry.pid)) — raise=\(raised.rawValue) "
            + "setMain=\(setMain.rawValue) activate=\(activated)")
    }

    /// Called on every release, whether or not a sweep happened, so the log can show how
    /// far the pointer travelled against the threshold it needed to cross.
    func endHold() {
        if totalX != 0 || totalY != 0 {
            log(String(format: "cycle: hold ended, swept x=%.0f y=%.0f (need %.0f)",
                       totalX, totalY, Self.pixelsPerStep))
        }
        totalX = 0
        totalY = 0
        finish()
    }

    /// Called when the Uber key is released. Flushes any raise the rate limit was still
    /// holding, so you always end on the window you chose. The list order and the cursor
    /// are deliberately left alone — that is what lets the next swipe go back the other way.
    func finish() {
        guard scrubbing else { return }
        scrubbing = false
        travelX = 0
        travelY = 0
        if pendingRaise != nil {
            pendingRaise?.cancel()
            performRaise()
        }
        rearmWork?.cancel()
        rearmWork = nil
        armed = true
        lastStepDir = 0
        lastStepAxis = .none
        log("cycle: finished at [\(index)]")
    }

    func cancel() {
        pendingRaise?.cancel()
        pendingRaise = nil
        rearmWork?.cancel()
        rearmWork = nil
        armed = true
        lastStepDir = 0
        lastStepAxis = .none
        scrubbing = false
        travelX = 0
        travelY = 0
    }
}


// MARK: - Updates

/// Checks GitHub for a newer release and installs it.
///
/// The safety of this rests on one check: the downloaded copy must carry the *same*
/// designated requirement as the running copy — same bundle identifier, same signing
/// certificate. Without that, a self-updating app is a remote code execution hole. It also
/// means the user's Accessibility grant carries across the update, because as far as macOS
/// is concerned it is still the same app.
///
/// Deliberately does nothing when a launch agent exists: that copy was built from source
/// by install.sh, and replacing it with a released build would throw away local changes.
enum Updater {
    static let repo = "b3nhartl3y/uberkey"

    /// Off by default. Replacing the app and relaunching it without being asked is a
    /// surprise, so it is opt-in; "Update now" is always available either way.
    static var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: "autoUpdate") }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private(set) static var availableVersion: String?
    private(set) static var lastResult = "not checked yet"
    static var onStateChange: (() -> Void)?

    /// Numeric compare, so 1.10 beats 1.9. Pure, and asserted in --selftest.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static var managedBySource: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/agency.honcho.uberkey.plist").path)
    }

    static func check(userAsked: Bool, thenInstall: Bool = false) {
        if managedBySource, !userAsked {
            lastResult = "managed by install.sh"
            return
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                DispatchQueue.main.async {
                    lastResult = "check failed: \(error?.localizedDescription ?? "bad response")"
                    log("update: \(lastResult)")
                    onStateChange?()
                }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let zip = (json["assets"] as? [[String: Any]])?
                .first { ($0["name"] as? String) == "Uberkey.zip" }?["browser_download_url"] as? String

            DispatchQueue.main.async {
                guard isNewer(version, than: currentVersion) else {
                    availableVersion = nil
                    lastResult = "up to date (\(currentVersion))"
                    log("update: \(lastResult)")
                    onStateChange?()
                    return
                }
                availableVersion = version
                lastResult = "\(version) available"
                log("update: \(lastResult)")
                onStateChange?()
                let shouldInstall = (thenInstall || automatic) && !managedBySource
                if shouldInstall, let zip, let zipURL = URL(string: zip) {
                    install(from: zipURL, version: version)
                } else if thenInstall, managedBySource {
                    lastResult = "\(version) available — this copy is managed by install.sh"
                    onStateChange?()
                }
            }
        }.resume()
    }

    static func install(from zipURL: URL, version: String) {
        log("update: downloading \(version)")
        URLSession.shared.downloadTask(with: zipURL) { temp, _, error in
            guard let temp else {
                DispatchQueue.main.async {
                    lastResult = "download failed: \(error?.localizedDescription ?? "unknown")"
                    log("update: \(lastResult)")
                    onStateChange?()
                }
                return
            }
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("uberkey-update-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("Uberkey.zip")
            try? FileManager.default.moveItem(at: temp, to: zip)

            // ditto, not unzip: it restores the signature and resource forks intact.
            _ = shell("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let candidate = work.appendingPathComponent("Uberkey.app")

            let verdict = verify(candidate)
            DispatchQueue.main.async {
                guard verdict == nil else {
                    lastResult = "update rejected: \(verdict!)"
                    log("update: \(lastResult)")
                    onStateChange?()
                    return
                }
                swapIn(candidate, version: version)
            }
        }.resume()
    }

    /// Returns nil when the candidate is safe to install, or the reason it is not.
    private static func verify(_ candidate: URL) -> String? {
        guard FileManager.default.fileExists(atPath: candidate.path) else { return "no app in the zip" }

        let intact = shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        guard !intact.lowercased().contains("invalid"), !intact.lowercased().contains("not signed")
        else { return "signature does not verify" }

        func requirement(_ path: String) -> String {
            shell("/usr/bin/codesign", ["-d", "--requirements", "-", path])
                .split(separator: "\n").first { $0.contains("designated =>") }
                .map(String.init) ?? ""
        }
        let ours = requirement(Bundle.main.bundlePath)
        let theirs = requirement(candidate.path)
        guard !ours.isEmpty else { return "cannot read our own requirement" }
        guard ours == theirs else { return "signed by someone else" }
        return nil
    }

    private static func swapIn(_ candidate: URL, version: String) {
        let live = URL(fileURLWithPath: Bundle.main.bundlePath)
        let backup = live.deletingLastPathComponent()
            .appendingPathComponent("Uberkey.app.old-\(currentVersion)")
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: live, to: backup)
            try FileManager.default.moveItem(at: candidate, to: live)
        } catch {
            // Put it back rather than leave nothing installed.
            try? FileManager.default.moveItem(at: backup, to: live)
            lastResult = "install failed: \(error.localizedDescription)"
            log("update: \(lastResult)")
            onStateChange?()
            return
        }
        try? FileManager.default.removeItem(at: backup)
        log("update: installed \(version), relaunching")

        // Relaunch through open, then exit non-zero so a launchd-managed copy is restarted
        // too. Whichever starts first takes the lock; the other exits.
        _ = shell("/usr/bin/open", ["-n", live.path])
        HyperModifiers.release()
        exit(1)
    }
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

    // The status file is written by the running instance, so with nothing running it is
    // a leftover from last time rather than the truth.
    let status = (try? String(contentsOf: supportDir().appendingPathComponent("status"),
                              encoding: .utf8)) ?? "(no status file)"
    row("tap", running ? status : "\(status)  — STALE, nothing is running")
    if running && status != "live" { problems.append("tap is not live: \(status)") }

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
    row("updates", Updater.managedBySource
        ? "managed by install.sh (git pull && ./install.sh)"
        : (Updater.automatic ? "automatic" : "manual"))

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

// Checks GitHub and reports, without installing anything. Lets the update path be tested
// without waiting a day or clicking a menu.
if CommandLine.arguments.contains("--check-updates") {
    Updater.check(userAsked: true)
    // The completion hops to the main queue, so the run loop has to be serviced for it to
    // arrive at all — there is no NSApplication in this mode.
    let deadline = Date().addingTimeInterval(20)
    while Updater.lastResult.hasPrefix("not checked"), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    print("installed \(Updater.currentVersion) — \(Updater.lastResult)")
    exit(Updater.availableVersion == nil ? 0 : 10)
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
