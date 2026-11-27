import AppKit

/// Watches for Option being held on its own. Pressing any other key, modifier, or
/// mouse button while it's held cancels, so ⌥-shortcuts and ⌥-typing keep working.
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}
    var hotkey: () -> Config.Hotkey = { .option }

    private var monitors: [Any] = []
    private var held = false
    private var cancelled = false

    // Device-dependent modifier bits from IOKit's NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK.
    private static let leftOptionBit: UInt = 0x20
    private static let rightOptionBit: UInt = 0x40

    func install() {
        uninstall()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func handle(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Paster.marker { return }
        guard event.type == .flagsChanged else {
            cancelIfHeld()
            return
        }
        let flags = event.modifierFlags
        let left = flags.rawValue & Self.leftOptionBit != 0
        let right = flags.rawValue & Self.rightOptionBit != 0
        let target: Bool
        let otherOption: Bool
        switch hotkey() {
        case .option: (target, otherOption) = (flags.contains(.option), false)
        case .leftOption: (target, otherOption) = (left, right)
        case .rightOption: (target, otherOption) = (right, left)
        }
        let otherModifiers = !flags.intersection([.command, .control, .shift, .function]).isEmpty || otherOption

        if !held {
            if target && !otherModifiers {
                held = true
                cancelled = false
                onPress()
            }
        } else if !target {
            held = false
            if !cancelled { onRelease() }
        } else if otherModifiers {
            cancelIfHeld()
        }
    }

    private func cancelIfHeld() {
        guard held, !cancelled else { return }
        cancelled = true
        onCancel()
    }
}
