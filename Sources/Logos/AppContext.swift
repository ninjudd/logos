import AppKit
import ApplicationServices

/// What's around a dictation, for the cleanup prompt's {{context}}: what the
/// focused field shows, and hints apps leave in context.d.
struct AppContext: Equatable {
    struct Hint: Equatable {
        /// The context.d file's name, so the prompt says where a hint came from.
        var source: String
        var text: String
    }

    var windowTitle: String?
    var url: String?
    var placeholder: String?
    var before: String?
    var after: String?
    var hints: [Hint] = []

    static let beforeLimit = 600
    static let afterLimit = 200

    /// The context as it appears in the cleanup prompt, or "(none)".
    func render() -> String {
        var lines: [String] = []
        if let windowTitle { lines.append("Window title: \(windowTitle)") }
        if let url { lines.append("Page: \(url)") }
        if let placeholder { lines.append("The field's placeholder: \(placeholder)") }
        if let before { lines.append("Text before the cursor:\n<before>\n\(before)\n</before>") }
        if let after { lines.append("Text after the cursor:\n<after>\n\(after)\n</after>") }
        for hint in hints { lines.append("From \(hint.source): \(hint.text)") }
        return lines.isEmpty ? "(none)" : lines.joined(separator: "\n")
    }

    // MARK: Reading the focused field

    /// Reads the focused window and field of `app` through Accessibility.
    /// Password fields are never read, and a slow app can't hold Logos up for
    /// more than a moment.
    static func capture(app: NSRunningApplication?) -> AppContext {
        var context = AppContext()
        guard AXIsProcessTrusted(), let pid = app?.processIdentifier else { return context }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        if let window = element(appElement, kAXFocusedWindowAttribute) {
            context.windowTitle = string(window, kAXTitleAttribute)
        }
        guard let field = element(appElement, kAXFocusedUIElementAttribute) else { return context }
        if string(field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String { return context }

        context.placeholder = string(field, kAXPlaceholderValueAttribute)
        context.url = pageURL(above: field)
        if let selection = range(field, kAXSelectedTextRangeAttribute) {
            let start = max(0, selection.location - beforeLimit)
            if let before = text(field, CFRange(location: start, length: selection.location - start)) {
                context.before = (start > 0 ? "…" : "") + before
            }
            let afterStart = selection.location + selection.length
            let total = int(field, kAXNumberOfCharactersAttribute) ?? afterStart
            let afterLength = min(afterLimit, max(0, total - afterStart))
            if let after = text(field, CFRange(location: afterStart, length: afterLength)) {
                context.after = after + (afterStart + afterLength < total ? "…" : "")
            }
        }
        return context
    }

    /// A browser's page URL, from the web area that contains the field.
    private static func pageURL(above field: AXUIElement) -> String? {
        var current: AXUIElement? = field
        for _ in 0..<40 {
            guard let element = current else { return nil }
            if string(element, kAXRoleAttribute) == "AXWebArea" {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
                return (value as? URL)?.absoluteString
            }
            current = self.element(element, kAXParentAttribute)
        }
        return nil
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ element: AXUIElement, _ name: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func range(_ element: AXUIElement, _ name: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    /// The field's text in `range`, trimmed, or nil when it's empty.
    private static func text(_ element: AXUIElement, _ range: CFRange) -> String? {
        guard range.length > 0 else { return nil }
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let text = value as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

/// Context that apps opt in to providing, by writing JSON files to
/// ~/.config/logos/context.d/. Logos reads them at every dictation.
enum ContextFiles {
    /// One file's contents. Every field is optional.
    struct File: Decodable {
        /// Bundle IDs of the apps the file applies to. Without it, it applies everywhere.
        var apps: [String]?
        /// Dictionary lines: words to transcribe and spell, each with an optional note after ": ".
        var words: [String]?
        /// A hint for the cleanup prompt.
        var prompt: String?
        /// After this time the file is ignored, so stale context from a closed session fades.
        var expires: Date?
    }

    struct Loaded: Equatable {
        var words: [Vocabulary.Entry] = []
        var hints: [AppContext.Hint] = []
    }

    static let promptLimit = 2000

    /// The words and hints of every file that applies to `bundleID` now.
    static func load(bundleID: String?, now: Date = Date(), dir: URL = Paths.contextDir) -> Loaded {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var loaded = Loaded()
        for url in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let file = try? decode(data) else {
                NSLog("Logos: ignoring %@, which isn't a valid context file", url.lastPathComponent)
                continue
            }
            guard applies(file, to: bundleID, now: now) else { continue }
            loaded.words += Vocabulary.parse((file.words ?? []).joined(separator: "\n"))
            if let prompt = file.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                loaded.hints.append(.init(source: url.deletingPathExtension().lastPathComponent,
                                          text: String(prompt.prefix(promptLimit))))
            }
        }
        return loaded
    }

    static func decode(_ data: Data) throws -> File {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expires must be an ISO 8601 time"))
        }
        return try decoder.decode(File.self, from: data)
    }

    static func applies(_ file: File, to bundleID: String?, now: Date) -> Bool {
        if let expires = file.expires, expires <= now { return false }
        guard let apps = file.apps, !apps.isEmpty else { return true }
        return bundleID.map(apps.contains) ?? false
    }
}
