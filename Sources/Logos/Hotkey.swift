import AppKit

/// The key you hold to dictate: a single modifier, such as "option" or
/// "rightCommand", or any key with optional modifiers, such as "f13" or
/// "ctrl+space". In config.json it's written as that string.
struct Hotkey: Codable, Equatable, CustomStringConvertible {
    enum Modifier: String, CaseIterable {
        case option, leftOption, rightOption
        case command, leftCommand, rightCommand
        case control, leftControl, rightControl
        case shift, leftShift, rightShift
        case fn
    }

    enum Kind: Equatable {
        case modifier(Modifier)
        /// A key by virtual key code, with the modifiers that must be held with it.
        case key(code: UInt16, modifiers: NSEvent.ModifierFlags)
    }

    var kind: Kind

    static let option = Hotkey(kind: .modifier(.option))

    /// The modifiers a key hotkey can require.
    static let comboModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    init(kind: Kind) {
        if case .key(let code, let modifiers) = kind {
            self.kind = .key(code: code, modifiers: modifiers.intersection(Self.comboModifiers))
        } else {
            self.kind = kind
        }
    }

    /// Parses "option", "rightCommand", "fn", "f13", "ctrl+space", "cmd+shift+d",
    /// or "key105" for a key by its virtual key code.
    init?(_ spec: String) {
        let parts = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        if parts.count == 1, let modifier = Modifier.allCases.first(where: { $0.rawValue.lowercased() == last.lowercased() }) {
            self.init(kind: .modifier(modifier))
            return
        }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard let code = Keys.code(named: last) else { return nil }
        self.init(kind: .key(code: code, modifiers: modifiers))
    }

    /// The string config.json holds.
    var spec: String {
        switch kind {
        case .modifier(let modifier):
            return modifier.rawValue
        case .key(let code, let modifiers):
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("ctrl") }
            if modifiers.contains(.option) { parts.append("opt") }
            if modifiers.contains(.shift) { parts.append("shift") }
            if modifiers.contains(.command) { parts.append("cmd") }
            return (parts + [Keys.name(of: code)]).joined(separator: "+")
        }
    }

    /// How menus and Settings show the hotkey, such as "Right Option" or "⌃Space".
    var description: String {
        switch kind {
        case .modifier(let modifier):
            switch modifier {
            case .option: return "Option"
            case .command: return "Command"
            case .control: return "Control"
            case .shift: return "Shift"
            case .fn: return "Fn"
            default:
                // "rightCommand" → "Right Command"
                let name = modifier.rawValue
                let split = name.firstIndex(where: \.isUppercase)!
                return name[..<split].capitalized + " " + name[split...]
            }
        case .key(let code, let modifiers):
            var symbols = ""
            if modifiers.contains(.control) { symbols += "⌃" }
            if modifiers.contains(.option) { symbols += "⌥" }
            if modifiers.contains(.shift) { symbols += "⇧" }
            if modifiers.contains(.command) { symbols += "⌘" }
            return symbols + Keys.display(of: code)
        }
    }

    /// True for a key that types a character, which would stop typing in every
    /// app while Logos runs.
    var typesText: Bool {
        guard case .key(let code, let modifiers) = kind else { return false }
        return modifiers.isDisjoint(with: [.command, .control]) && Keys.typing.contains(code)
    }

    init(from decoder: Decoder) throws {
        let spec = try decoder.singleValueContainer().decode(String.self)
        guard let hotkey = Hotkey(spec) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "\"\(spec)\" isn't a key Logos knows"))
        }
        self = hotkey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(spec)
    }
}

/// Names for macOS virtual key codes, as on a US keyboard.
enum Keys {
    private static let table: [(String, UInt16, String)] = [
        ("a", 0, "A"), ("s", 1, "S"), ("d", 2, "D"), ("f", 3, "F"), ("h", 4, "H"), ("g", 5, "G"), ("z", 6, "Z"),
        ("x", 7, "X"), ("c", 8, "C"), ("v", 9, "V"), ("b", 11, "B"), ("q", 12, "Q"), ("w", 13, "W"), ("e", 14, "E"),
        ("r", 15, "R"), ("y", 16, "Y"), ("t", 17, "T"), ("1", 18, "1"), ("2", 19, "2"), ("3", 20, "3"), ("4", 21, "4"),
        ("6", 22, "6"), ("5", 23, "5"), ("equal", 24, "="), ("9", 25, "9"), ("7", 26, "7"), ("minus", 27, "-"),
        ("8", 28, "8"), ("0", 29, "0"), ("rightbracket", 30, "]"), ("o", 31, "O"), ("u", 32, "U"),
        ("leftbracket", 33, "["), ("i", 34, "I"), ("p", 35, "P"), ("return", 36, "Return"), ("l", 37, "L"),
        ("j", 38, "J"), ("quote", 39, "'"), ("k", 40, "K"), ("semicolon", 41, ";"), ("backslash", 42, "\\"),
        ("comma", 43, ","), ("slash", 44, "/"), ("n", 45, "N"), ("m", 46, "M"), ("period", 47, "."),
        ("tab", 48, "Tab"), ("space", 49, "Space"), ("grave", 50, "`"), ("delete", 51, "Delete"),
        ("escape", 53, "Esc"), ("f17", 64, "F17"), ("f18", 79, "F18"), ("f19", 80, "F19"), ("f20", 90, "F20"),
        ("f5", 96, "F5"), ("f6", 97, "F6"), ("f7", 98, "F7"), ("f3", 99, "F3"), ("f8", 100, "F8"), ("f9", 101, "F9"),
        ("f11", 103, "F11"), ("f13", 105, "F13"), ("f16", 106, "F16"), ("f14", 107, "F14"), ("f10", 109, "F10"),
        ("f12", 111, "F12"), ("f15", 113, "F15"), ("help", 114, "Help"), ("home", 115, "Home"),
        ("pageup", 116, "Page Up"), ("forwarddelete", 117, "⌦"), ("f4", 118, "F4"), ("end", 119, "End"),
        ("f2", 120, "F2"), ("pagedown", 121, "Page Down"), ("f1", 122, "F1"), ("left", 123, "←"),
        ("right", 124, "→"), ("down", 125, "↓"), ("up", 126, "↑"),
    ]
    private static let symbols: [String: String] = [
        "=": "equal", "-": "minus", "]": "rightbracket", "[": "leftbracket", "'": "quote", ";": "semicolon",
        "\\": "backslash", ",": "comma", "/": "slash", ".": "period", "`": "grave", "esc": "escape",
        "enter": "return", "backspace": "delete",
    ]

    /// Keys that type a character: letters, digits, punctuation, and Space.
    static let typing: Set<UInt16> = Set(table.filter { $0.0.count == 1 || $0.2.count == 1 }.map(\.1)).union([49])

    static func code(named name: String) -> UInt16? {
        let lowered = name.lowercased()
        let canonical = symbols[lowered] ?? symbols[name] ?? lowered
        if let entry = table.first(where: { $0.0 == canonical }) { return entry.1 }
        if canonical.hasPrefix("key"), let code = UInt16(canonical.dropFirst(3)) { return code }
        return nil
    }

    static func name(of code: UInt16) -> String {
        table.first { $0.1 == code }?.0 ?? "key\(code)"
    }

    static func display(of code: UInt16) -> String {
        table.first { $0.1 == code }?.2 ?? "Key \(code)"
    }
}
