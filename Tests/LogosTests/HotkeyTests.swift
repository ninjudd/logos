import AppKit
import Foundation
import Testing
@testable import Logos

@Suite struct HotkeyTests {
    // Catches configs written before any key was allowed failing to load.
    @Test func optionNamesFromBeforeStillWork() throws {
        for (spec, kind) in [("option", Hotkey.Kind.modifier(.option)), ("leftOption", .modifier(.leftOption)),
                             ("rightOption", .modifier(.rightOption))] {
            #expect(try Config.decode(Data(#"{"hotkey": "\#(spec)"}"#.utf8)).hotkey.kind == kind)
        }
    }

    @Test func parsesModifiersKeysAndCombinations() {
        #expect(Hotkey("rightCommand")?.kind == .modifier(.rightCommand))
        #expect(Hotkey("FN")?.kind == .modifier(.fn))
        #expect(Hotkey("f13")?.kind == .key(code: 105, modifiers: []))
        #expect(Hotkey("ctrl+space")?.kind == .key(code: 49, modifiers: .control))
        #expect(Hotkey("cmd + shift + d")?.kind == .key(code: 2, modifiers: [.command, .shift]))
        #expect(Hotkey("⌥`")?.kind == nil)
        #expect(Hotkey("opt+`")?.kind == .key(code: 50, modifiers: .option))
        #expect(Hotkey("key200")?.kind == .key(code: 200, modifiers: []))
    }

    @Test func rejectsWhatItCantName() {
        #expect(Hotkey("") == nil)
        #expect(Hotkey("hyper+a") == nil)
        #expect(Hotkey("banana") == nil)
    }

    // Catches a recorded hotkey that config.json can't read back.
    @Test func specsRoundTrip() {
        for spec in ["option", "rightCommand", "fn", "f13", "ctrl+space", "ctrl+opt+shift+cmd+k", "key200", "slash"] {
            #expect(Hotkey(spec)?.spec == spec)
        }
    }

    @Test func descriptions() {
        #expect(Hotkey("option")?.description == "Option")
        #expect(Hotkey("rightCommand")?.description == "Right Command")
        #expect(Hotkey("leftShift")?.description == "Left Shift")
        #expect(Hotkey("ctrl+space")?.description == "⌃Space")
        #expect(Hotkey("cmd+shift+d")?.description == "⇧⌘D")
        #expect(Hotkey("f13")?.description == "F13")
    }

    // Catches no warning for a hotkey that would stop a letter from typing anywhere.
    @Test func warnsOnlyForKeysThatTypeText() {
        #expect(Hotkey("a")?.typesText == true)
        #expect(Hotkey("space")?.typesText == true)
        #expect(Hotkey("shift+slash")?.typesText == true)
        #expect(Hotkey("ctrl+space")?.typesText == false)
        #expect(Hotkey("f13")?.typesText == false)
        #expect(Hotkey("option")?.typesText == false)
    }
}

@Suite struct HotkeyMonitorTests {
    private final class Log {
        var events: [String] = []
    }

    private func monitor(_ spec: String, _ log: Log) -> HotkeyMonitor {
        let monitor = HotkeyMonitor()
        monitor.hotkey = { Hotkey(spec)! }
        monitor.onPress = { log.events.append("press") }
        monitor.onRelease = { log.events.append("release") }
        monitor.onCancel = { log.events.append("cancel") }
        return monitor
    }

    private func key(_ code: UInt16, down: Bool, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        return event
    }

    private func modifiers(_ code: UInt16, _ flags: CGEventFlags) -> CGEvent {
        let event = key(code, down: true, flags: flags)
        event.type = .flagsChanged
        return event
    }

    private static let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    private static let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)

    @Test func modifierHeldAloneDictates() {
        let log = Log(), monitor = monitor("rightOption", log)
        #expect(!monitor.handle(.flagsChanged, modifiers(61, Self.rightOption)))
        #expect(!monitor.handle(.flagsChanged, modifiers(61, [])))
        #expect(log.events == ["press", "release"])
    }

    // Catches the left key starting a dictation when you chose the right one.
    @Test func otherSideDoesNothing() {
        let log = Log(), monitor = monitor("rightOption", log)
        _ = monitor.handle(.flagsChanged, modifiers(58, Self.leftOption))
        _ = monitor.handle(.flagsChanged, modifiers(58, []))
        #expect(log.events.isEmpty)
    }

    // Catches ⌥-shortcuts and ⌥-typing turning into dictations.
    @Test func typingWhileHoldingAModifierCancels() {
        let log = Log(), monitor = monitor("option", log)
        _ = monitor.handle(.flagsChanged, modifiers(58, Self.leftOption))
        #expect(!monitor.handle(.keyDown, key(0, down: true, flags: Self.leftOption)))
        _ = monitor.handle(.flagsChanged, modifiers(58, []))
        #expect(log.events == ["press", "cancel"])
    }

    // Catches a key hotkey reaching the app you're typing in, or repeating into it.
    @Test func keyHotkeyIsSwallowedWithItsRepeatsAndRelease() {
        let log = Log(), monitor = monitor("f13", log)
        #expect(monitor.handle(.keyDown, key(105, down: true)))
        #expect(monitor.handle(.keyDown, key(105, down: true)))
        #expect(monitor.handle(.keyUp, key(105, down: false)))
        #expect(log.events == ["press", "release"])
    }

    // Catches ⌥Space starting a dictation set for ⌃Space, or plain Space being swallowed.
    @Test func keyHotkeyNeedsExactlyItsModifiers() {
        let log = Log(), monitor = monitor("ctrl+space", log)
        #expect(!monitor.handle(.keyDown, key(49, down: true)))
        #expect(!monitor.handle(.keyDown, key(49, down: true, flags: .maskAlternate)))
        #expect(monitor.handle(.keyDown, key(49, down: true, flags: .maskControl)))
        #expect(log.events == ["press"])
    }

    // Catches Fn, which macOS sets on its own for function keys, blocking an F-key hotkey.
    @Test func fnFlagIsIgnoredForKeys() {
        let log = Log(), monitor = monitor("f13", log)
        #expect(monitor.handle(.keyDown, key(105, down: true, flags: .maskSecondaryFn)))
        #expect(log.events == ["press"])
    }

    @Test func otherKeysPassThroughAndCancelAHeldKey() {
        let log = Log(), monitor = monitor("f13", log)
        _ = monitor.handle(.keyDown, key(105, down: true))
        #expect(!monitor.handle(.keyDown, key(0, down: true)))
        #expect(monitor.handle(.keyUp, key(105, down: false)))
        #expect(log.events == ["press", "cancel"])
    }

    // Catches the old hotkey starting a dictation while Settings records a new one.
    @Test func suspendedMonitorIgnoresEverything() {
        let log = Log(), monitor = monitor("f13", log)
        monitor.isSuspended = true
        #expect(!monitor.handle(.keyDown, key(105, down: true)))
        #expect(log.events.isEmpty)
    }

    // Catches Logos's own ⌘V paste cancelling or starting a dictation.
    @Test func ownPasteIsIgnored() {
        let log = Log(), monitor = monitor("cmd+v", log)
        let paste = key(9, down: true, flags: .maskCommand)
        paste.setIntegerValueField(.eventSourceUserData, value: Paster.marker)
        #expect(!monitor.handle(.keyDown, paste))
        #expect(log.events.isEmpty)
    }
}
