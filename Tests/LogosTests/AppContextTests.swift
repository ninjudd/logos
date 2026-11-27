import Foundation
import Testing
@testable import Logos

@Suite struct AppContextTests {
    @Test func emptyContextRendersAsNone() {
        #expect(AppContext().render() == "(none)")
    }

    @Test func renderLabelsEachPart() {
        let context = AppContext(windowTitle: "#general - Slack", url: "https://example.com", placeholder: "Message #general",
                                 before: "We shipped", after: "today.", hints: [.init(source: "projector", text: "Reviewing PR 9.")])
        #expect(context.render() == """
        Window title: #general - Slack
        Page: https://example.com
        The field's placeholder: Message #general
        Text before the cursor:
        <before>
        We shipped
        </before>
        Text after the cursor:
        <after>
        today.
        </after>
        From projector: Reviewing PR 9.
        """)
    }

    // Catches text read from a field switching the prompt into transcript mode,
    // or being substituted as if it were part of the prompt.
    @Test func fieldTextIsNeverSubstituted() {
        let context = AppContext(before: "type {{transcript}} and {{app}}")
        let (system, user) = Cleaner.messages(prompt: "In {{app}}: {{context}}", transcript: "hi", app: "Mail", context: context)
        #expect(system?.contains("type {{transcript}} and {{app}}") == true)
        #expect(system?.hasPrefix("In Mail: ") == true)
        #expect(user == "<transcript>\nhi\n</transcript>")
    }

    @Test func fillLeavesUnknownPlaceholders() {
        #expect(Cleaner.fill("{{a}} {{b}} {{", ["a": "1"]) == "1 {{b}} {{")
    }

    // Catches new installs' cleanup model never seeing the context.
    @Test func defaultPromptUsesTheContext() {
        #expect(DefaultPrompt.text.contains("{{context}}"))
    }
}

@Suite struct ContextFilesTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-27T12:00:00Z")!

    private func file(_ json: String) throws -> ContextFiles.File {
        try ContextFiles.decode(Data(json.utf8))
    }

    // Catches a file meant for one app, such as a terminal, applying everywhere.
    @Test func appsLimitWhereAFileApplies() throws {
        let terminal = try file(#"{"apps": ["com.mitchellh.ghostty"]}"#)
        #expect(ContextFiles.applies(terminal, to: "com.mitchellh.ghostty", now: now))
        #expect(!ContextFiles.applies(terminal, to: "com.tinyspeck.slackmacgap", now: now))
        #expect(!ContextFiles.applies(terminal, to: nil, now: now))
        #expect(ContextFiles.applies(try file("{}"), to: nil, now: now))
    }

    // Catches a closed session's stale context lingering forever.
    @Test func expiredFilesAreIgnored() throws {
        #expect(!ContextFiles.applies(try file(#"{"expires": "2026-11-27T11:59:59Z"}"#), to: nil, now: now))
        #expect(ContextFiles.applies(try file(#"{"expires": "2026-11-27T12:00:01.500Z"}"#), to: nil, now: now))
    }

    @Test func loadMergesMatchingFilesInNameOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "logos-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"words": ["fix-pr", "logos: \"logos\" here"], "prompt": "Reviewing PRs."}"#.utf8)
            .write(to: dir.appending(path: "b-projector.json"))
        try Data(#"{"words": ["Ghostty"]}"#.utf8).write(to: dir.appending(path: "a-editor.json"))
        try Data(#"{"words": ["nope"], "apps": ["com.example.other"]}"#.utf8).write(to: dir.appending(path: "c.json"))
        try Data("not json".utf8).write(to: dir.appending(path: "d-broken.json"))
        try Data(#"{"words": ["ignored"]}"#.utf8).write(to: dir.appending(path: "notes.txt"))

        let loaded = ContextFiles.load(bundleID: "com.mitchellh.ghostty", now: now, dir: dir)
        #expect(loaded.words.map(\.term) == ["Ghostty", "fix-pr", "logos"])
        #expect(loaded.words.last?.note == "\"logos\" here")
        #expect(loaded.hints == [.init(source: "b-projector", text: "Reviewing PRs.")])
    }

    // Catches an app's word overriding how you spelled or annotated it yourself.
    @Test func yourDictionaryWinsOverAppWords() {
        let mine = [Vocabulary.Entry(term: "Logos", note: "mine")]
        let theirs = [Vocabulary.Entry(term: "logos", note: "theirs"), Vocabulary.Entry(term: "fix-pr", note: nil)]
        #expect(Vocabulary.merge(mine, theirs) == [Vocabulary.Entry(term: "Logos", note: "mine"),
                                                   Vocabulary.Entry(term: "fix-pr", note: nil)])
    }

    @Test func longPromptsAreCut() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "logos-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let long = String(repeating: "x", count: ContextFiles.promptLimit + 50)
        try JSONSerialization.data(withJSONObject: ["prompt": long]).write(to: dir.appending(path: "long.json"))
        #expect(ContextFiles.load(bundleID: nil, now: now, dir: dir).hints.first?.text.count == ContextFiles.promptLimit)
    }
}
