// SlowMo — brings back "hold a key while minimizing for slow motion" on modern macOS.
//
// How it works:
//  1. The Dock still contains Apple's slow-motion code; since High Sierra it is just
//     switched off. SlowMo turns it back on (com.apple.dock slow-motion-allowed = YES)
//     and restarts the Dock. With that alone, Shift + minimize works again.
//  2. If you pick a different trigger key (Fn, Control, Option, Command or any regular
//     key), SlowMo watches for it and, while it is held, presses a virtual Shift for you
//     so the Dock sees Shift. This part needs Accessibility permission.

import Cocoa
import ServiceManagement

private let kSyntheticMarker: Int64 = 0x534C_4F57 // "SLOW" — tags events we post ourselves
private let kShiftKeyCode: CGKeyCode = 56

struct Trigger: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case shift, fn, control, option, command, custom
    }

    var kind: Kind
    var keyCode: Int64 = -1
    var name: String = ""

    var flag: CGEventFlags {
        switch kind {
        case .shift: return .maskShift
        case .fn: return .maskSecondaryFn
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .custom: return []
        }
    }

    /// Hardware key codes that produce flagsChanged events for this modifier (left/right).
    var modifierKeyCodes: Set<Int64> {
        switch kind {
        case .shift: return [56, 60]
        case .fn: return [63, 179]
        case .control: return [59, 62]
        case .option: return [58, 61]
        case .command: return [55, 54]
        case .custom: return []
        }
    }

    var title: String {
        switch kind {
        case .shift: return "Shift ⇧ (built-in)"
        case .fn: return "Fn / Globe 🌐"
        case .control: return "Control ⌃"
        case .option: return "Option ⌥"
        case .command: return "Command ⌘"
        case .custom: return name.isEmpty ? "Custom key…" : "Custom key: \(name)"
        }
    }
}

final class SlowMo: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var trustTimer: Timer?
    private var shiftActive = false
    private var recording = false
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    private var trigger: Trigger = Trigger(kind: .shift) {
        didSet {
            if let data = try? JSONEncoder().encode(trigger) {
                UserDefaults.standard.set(data, forKey: "trigger")
            }
            updateTap()
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = UserDefaults.standard.data(forKey: "trigger"),
           let saved = try? JSONDecoder().decode(Trigger.self, from: data) {
            trigger = saved
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tortoise.fill", accessibilityDescription: "SlowMo")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // First launch: open at login by default, so SlowMo survives a restart.
        if !UserDefaults.standard.bool(forKey: "didFirstRun") {
            UserDefaults.standard.set(true, forKey: "didFirstRun")
            try? SMAppService.mainApp.register()
        }

        // Every launch: if the Dock's slow motion should be on but isn't (first run, or a
        // macOS update/restart cleared it), switch it back on.
        if wantSlowMotion && !dockSlowMotionAllowed { setDockSlowMotion(true) }

        updateTap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if shiftActive { setVirtualShift(false) } // never leave Shift stuck down
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "SlowMo", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let enabled = NSMenuItem(title: "Slow-motion minimize", action: #selector(toggleDock), keyEquivalent: "")
        enabled.target = self
        enabled.state = dockSlowMotionAllowed ? .on : .off
        menu.addItem(enabled)

        menu.addItem(.separator())

        let hold = NSMenuItem(title: "Hold this key while minimizing:", action: nil, keyEquivalent: "")
        hold.isEnabled = false
        menu.addItem(hold)

        for kind in Trigger.Kind.allCases {
            let t: Trigger = (kind == trigger.kind) ? trigger : Trigger(kind: kind)
            var title = t.title
            if kind == .custom && recording { title = "Press any key… (Esc cancels)" }
            if kind == .custom && trigger.kind == .custom && !recording { title += "   (click to change)" }
            let item = NSMenuItem(title: title, action: #selector(pickTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = (kind == trigger.kind) ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }

        if needsTap && !AXIsProcessTrusted() {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "⚠︎ Allow Accessibility access…", action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        let tip = NSMenuItem(title: "Tip: hold the key, click a yellow ● button", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        menu.addItem(tip)

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit SlowMo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleDock() {
        let on = !dockSlowMotionAllowed
        wantSlowMotion = on
        setDockSlowMotion(on)
    }

    /// Whether the user wants slow motion on. Defaults to true; the menu toggle changes it.
    private var wantSlowMotion: Bool {
        get { UserDefaults.standard.object(forKey: "wantSlowMotion") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wantSlowMotion") }
    }

    @objc private func pickTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = Trigger.Kind(rawValue: raw) else { return }
        if kind == .custom {
            recording = true
            updateTap()
            // Re-open the menu so the "Press any key…" prompt is visible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        } else {
            recording = false
            trigger = Trigger(kind: kind)
        }
    }

    @objc private func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove SlowMo to your Applications folder and try again."
            alert.runModal()
        }
    }

    // MARK: - Dock setting

    private var dockSlowMotionAllowed: Bool {
        let out = run("/usr/bin/defaults", ["read", "com.apple.dock", "slow-motion-allowed"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func setDockSlowMotion(_ on: Bool) {
        if on {
            _ = run("/usr/bin/defaults", ["write", "com.apple.dock", "slow-motion-allowed", "-bool", "YES"])
        } else {
            _ = run("/usr/bin/defaults", ["delete", "com.apple.dock", "slow-motion-allowed"])
        }
        _ = run("/usr/bin/killall", ["Dock"]) // Dock relaunches itself and picks up the change
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - Event tap (only needed for non-Shift triggers)

    private var needsTap: Bool { trigger.kind != .shift || recording }

    private func updateTap() {
        if shiftActive { setVirtualShift(false) }
        guard needsTap else { removeTap(); return }
        if tap != nil { return }

        if AXIsProcessTrusted() {
            installTap()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            trustTimer?.invalidate()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    self.trustTimer = nil
                    if self.needsTap { self.installTap() }
                }
            }
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<SlowMo>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("SlowMo: could not create event tap (Accessibility permission missing?)")
            return
        }
        tap = newTap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }

    private func removeTap() {
        trustTimer?.invalidate()
        trustTimer = nil
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == kSyntheticMarker { return pass }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Recording a custom trigger key: capture the next key press.
        if recording && type == .keyDown {
            recording = false
            if keyCode == 53 { // Esc cancels
                DispatchQueue.main.async { self.updateTap() }
            } else {
                let newTrigger = Trigger(kind: .custom, keyCode: keyCode, name: keyName(for: event, keyCode: keyCode))
                DispatchQueue.main.async { self.trigger = newTrigger }
            }
            return nil
        }

        let t = trigger
        switch type {
        case .flagsChanged:
            if t.kind != .custom && t.kind != .shift && t.modifierKeyCodes.contains(keyCode) {
                let down = event.flags.contains(t.flag)
                if down != shiftActive { setVirtualShift(down) }
            }

        case .keyDown where t.kind == .custom && keyCode == t.keyCode:
            if !shiftActive { setVirtualShift(true) } // auto-repeats are swallowed too
            return nil

        case .keyUp where t.kind == .custom && keyCode == t.keyCode:
            if shiftActive { setVirtualShift(false) }
            return nil

        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            // While the trigger is held, make the click look like a plain Shift-click,
            // so e.g. Option doesn't turn it into "minimize all windows".
            if shiftActive {
                var f = event.flags
                f.remove(t.flag)
                f.insert(.maskShift)
                event.flags = f
            }

        default:
            break
        }
        return pass
    }

    /// Presses or releases a virtual Shift key at the hardware level.
    private func setVirtualShift(_ down: Bool) {
        shiftActive = down
        guard let e = CGEvent(keyboardEventSource: eventSource, virtualKey: kShiftKeyCode, keyDown: down) else { return }
        e.type = .flagsChanged
        var f = CGEventSource.flagsState(.combinedSessionState)
        if down { f.insert(.maskShift) } else { f.remove(.maskShift) }
        e.flags = f
        e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
        e.post(tap: .cghidEventTap)
    }

    private func keyName(for event: CGEvent, keyCode: Int64) -> String {
        let named: [Int64: String] = [
            49: "Space", 48: "Tab", 36: "Return", 51: "Delete", 117: "Forward Delete",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 115: "Home", 119: "End",
            116: "Page Up", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        if let n = named[keyCode] { return n }
        if let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return chars.uppercased()
        }
        return "Key \(keyCode)"
    }
}

let app = NSApplication.shared
let delegate = SlowMo()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
