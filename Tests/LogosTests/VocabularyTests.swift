import Foundation
import Testing
@testable import Logos

@Suite struct VocabularyTests {
    private typealias Entry = Vocabulary.Entry

    // Catches comment lines, blank lines, or stray spaces reaching the models.
    @Test func parseSkipsCommentsAndBlanks() {
        let text = "# names\nLogos\n\n  Ghostty  \n# Old\nNinjudd\n"
        #expect(Vocabulary.parse(text).map(\.term) == ["Logos", "Ghostty", "Ninjudd"])
    }

    // Catches "Logos" and "logos" both being listed, which would tell the model
    // two different spellings of one word.
    @Test func duplicatesInAnyCaseKeepTheFirst() {
        #expect(Vocabulary.parse("logos\nLogos\nLOGOS\n") == [Entry(term: "logos")])
    }

    @Test func noteFollowsColonSpace() {
        #expect(Vocabulary.parse("logos: \"Logos\" for the app, \"logos\" for the command") ==
            [Entry(term: "logos", note: "\"Logos\" for the app, \"logos\" for the command")])
        #expect(Vocabulary.parse("ratio: 3: 2 in photos") == [Entry(term: "ratio", note: "3: 2 in photos")])
    }

    // Catches splitting on any colon, which would break terms such as std::vector.
    @Test func colonWithoutASpaceStaysInTheTerm() {
        #expect(Vocabulary.parse("std::vector\nhttps://logosvoice.dev") ==
            [Entry(term: "std::vector"), Entry(term: "https://logosvoice.dev")])
    }

    @Test func defaultFileExplainsCaseWithANote() {
        let entries = Vocabulary.parse(Vocabulary.defaultText)
        #expect(entries.map(\.term) == ["logos"])
        #expect(entries.first?.note?.contains("command") == true)
    }

    @Test func promptListIncludesNotes() {
        #expect(Vocabulary.promptList([Entry(term: "logos", note: "\"Logos\" for the app"), Entry(term: "Ghostty")])
            == "- logos: \"Logos\" for the app\n- Ghostty")
        #expect(Vocabulary.promptList([]) == "(none)")
    }

    // Catches the dictionary replacing your own transcription prompt instead of joining it.
    @Test func transcriptionHintKeepsYourPrompt() {
        #expect(Vocabulary.transcriptionHint("", words: []) == "")
        #expect(Vocabulary.transcriptionHint("A podcast.", words: []) == "A podcast.")
        #expect(Vocabulary.transcriptionHint("", words: ["Logos", "Ghostty"]) == "Vocabulary: Logos, Ghostty. Nothing. …")
        #expect(Vocabulary.transcriptionHint("A podcast.", words: ["Logos"]) == "A podcast. Vocabulary: Logos. Nothing. …")
    }

    // Catches the hint ending with a dictionary word, which Whisper repeats
    // when given a breath, a click, or a voiced "oh".
    @Test func transcriptionHintEndsWithAPlaceholder() {
        #expect(Vocabulary.transcriptionHint("", words: ["alpha", "Zanzibar"]).hasSuffix("Zanzibar. Nothing. …"))
    }

    @Test func promptGetsTheDictionary() {
        let (system, _) = Cleaner.messages(prompt: "Spell these:\n{{dictionary}}", transcript: "hi", app: "Mail",
                                           vocabulary: [Entry(term: "Logos"), Entry(term: "Ghostty")])
        #expect(system == "Spell these:\n- Logos\n- Ghostty")
    }

    // Catches dictating the literal word "{{dictionary}}" being replaced with the list.
    @Test func placeholderInTheTranscriptIsLeftAlone() {
        let (_, user) = Cleaner.messages(prompt: "{{transcript}}", transcript: "say {{dictionary}}", app: "Mail",
                                         vocabulary: [Entry(term: "Logos")])
        #expect(user == "say {{dictionary}}")
    }

    // Catches the default prompt losing the placeholder or the rule that context
    // sets letter case.
    @Test func defaultPromptUsesTheDictionaryAndContextualCase() {
        #expect(DefaultPrompt.text.contains("{{dictionary}}"))
        #expect(DefaultPrompt.text.contains("letter case from context"))
    }

    @Test func appleModelNames() {
        #expect(Transcriber.AppleModel("apple") == .speech)
        #expect(Transcriber.AppleModel("apple/speech") == .speech)
        #expect(Transcriber.AppleModel("apple/dictation") == .dictation)
        #expect(Transcriber.AppleModel("openai/gpt-4o-transcribe") == nil)
    }
}

extension Vocabulary.Entry {
    init(term: String) { self.init(term: term, note: nil) }
}
