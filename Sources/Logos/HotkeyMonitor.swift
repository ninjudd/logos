import AppKit

/// Watches for the hotkey being held, through a Core Graphics event tap.
///
/// A modifier hotkey, such as Option, counts only when held on its own: any
/// other key, modifier, or mouse button while it's held cancels, so modifier
/// shortcuts and typing keep working. A key hotkey, such as F13 or ⌃Space, is
/// swallowed, along with its repeats and its release, so it never reaches the
/// app you're typing in. Swallowing needs an active tap, which runs under the
/// Accessibility permission Logos already has.
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Every key press in any app, by virtual key code.
    var onKeyDown: (UInt16) -> Void = { _ in }
    var hotkey: () -> Hotkey = { .option }
    /// While Settings records a new hotkey, every key goes to Settings instead.
    var isSuspended = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private var cancelled = false

    /// Starts the tap. It fails until Logos has Accessibility access, so it's
    /// called again once access is granted.
    func install() {
        uninstall()
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(info!).takeUnretainedValue()
                return monitor.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Handles one event and returns true to swallow it.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns off a tap that's slow or gets in the way; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Paster.marker || isSuspended { return false }
        switch hotkey().kind {
        case .modifier(let modifier):
            handleModifier(modifier, type, event)
            return false
        case .key(let code, let modifiers):
            return handleKey(code, modifiers, type, event)
        }
    }

    private func handleModifier(_ modifier: Hotkey.Modifier, _ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .flagsChanged:
            let flags = event.flags
            let down = Self.isDown(modifier, flags)
            let others = Self.othersDown(besides: modifier, flags)
            if !held {
                if down && !others { press() }
            } else if !down {
                release()
            } else if others {
                cancel()
            }
        case .keyDown:
            onKeyDown(UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
            cancel()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            cancel()
        default:
            break
        }
    }

    private func handleKey(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ type: CGEventType, _ event: CGEvent) -> Bool {
        let eventCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown where eventCode == code:
            if held { return true } // a repeat while held
            guard Self.comboModifiers(event.flags) == modifiers else { return false }
            press()
            return true
        case .keyDown:
            onKeyDown(eventCode)
            cancel()
            return false
        case .keyUp where eventCode == code && held:
            release()
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            cancel()
            return false
        default:
            return false
        }
    }

    private func press() {
        held = true
        cancelled = false
        onPress()
    }

    private func release() {
        held = false
        if !cancelled { onRelease() }
    }

    private func cancel() {
        guard held, !cancelled else { return }
        cancelled = true
        onCancel()
    }

    // MARK: Modifier flags

    // Device-dependent bits from IOKit's NX_DEVICE*KEYMASK, which tell left from right.
    private static let sideBits: [Hotkey.Modifier: UInt64] = [
        .leftControl: 0x01, .leftShift: 0x02, .rightShift: 0x04, .leftCommand: 0x08,
        .rightCommand: 0x10, .leftOption: 0x20, .rightOption: 0x40, .rightControl: 0x2000,
    ]

    private static let families: [(either: Hotkey.Modifier, left: Hotkey.Modifier?, right: Hotkey.Modifier?, flag: CGEventFlags)] = [
        (.option, .leftOption, .rightOption, .maskAlternate),
        (.command, .leftCommand, .rightCommand, .maskCommand),
        (.control, .leftControl, .rightControl, .maskControl),
        (.shift, .leftShift, .rightShift, .maskShift),
        (.fn, nil, nil, .maskSecondaryFn),
    ]

    static func isDown(_ modifier: Hotkey.Modifier, _ flags: CGEventFlags) -> Bool {
        if let bit = sideBits[modifier] { return flags.rawValue & bit != 0 }
        return families.first { $0.either == modifier }.map { flags.contains($0.flag) } ?? false
    }

    /// Whether any modifier other than `modifier` is held, including the other
    /// side of its own family when it names one side.
    static func othersDown(besides modifier: Hotkey.Modifier, _ flags: CGEventFlags) -> Bool {
        families.contains { family in
            if family.either == modifier { return false }
            if family.left == modifier { return family.right.map { isDown($0, flags) } ?? false }
            if family.right == modifier { return family.left.map { isDown($0, flags) } ?? false }
            return flags.contains(family.flag)
        }
    }

    /// The Command, Control, Option, and Shift keys held, ignoring Fn, which
    /// macOS sets by itself on function and arrow keys.
    static func comboModifiers(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }
}
