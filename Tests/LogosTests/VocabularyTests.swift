import Foundation
import Testing
@testable import Logos

@Suite struct VocabularyTests {
    // Catches comment lines, blank lines, or stray spaces reaching the models.
    @Test func parseSkipsCommentsBlanksAndDuplicates() {
        let text = "# names\nLogos\n\n  Ghostty  \n# Old\nLogos\nNinjudd\n"
        #expect(Vocabulary.parse(text) == ["Logos", "Ghostty", "Ninjudd"])
    }

    @Test func defaultFileHoldsOneWord() {
        #expect(Vocabulary.parse(Vocabulary.defaultText) == ["Logos"])
    }

    @Test func promptListIsBulleted() {
        #expect(Vocabulary.promptList(["Logos", "Ghostty"]) == "- Logos\n- Ghostty")
        #expect(Vocabulary.promptList([]) == "(none)")
    }

    // Catches the dictionary replacing your own transcription prompt instead of joining it.
    @Test func transcriptionHintKeepsYourPrompt() {
        #expect(Vocabulary.transcriptionHint("", words: []) == "")
        #expect(Vocabulary.transcriptionHint("A podcast.", words: []) == "A podcast.")
        #expect(Vocabulary.transcriptionHint("", words: ["Logos", "Ghostty"]) == "Vocabulary: Logos, Ghostty.")
        #expect(Vocabulary.transcriptionHint("A podcast.", words: ["Logos"]) == "A podcast. Vocabulary: Logos.")
    }

    @Test func promptGetsTheDictionary() {
        let (system, _) = Cleaner.messages(prompt: "Spell these:\n{{dictionary}}", transcript: "hi", app: "Mail",
                                           vocabulary: ["Logos", "Ghostty"])
        #expect(system == "Spell these:\n- Logos\n- Ghostty")
    }

    // Catches dictating the literal word "{{dictionary}}" being replaced with the list.
    @Test func placeholderInTheTranscriptIsLeftAlone() {
        let (_, user) = Cleaner.messages(prompt: "{{transcript}}", transcript: "say {{dictionary}}", app: "Mail",
                                         vocabulary: ["Logos"])
        #expect(user == "say {{dictionary}}")
    }

    // Catches the default prompt losing the placeholder, which would leave new
    // installs' cleanup model without the dictionary.
    @Test func defaultPromptUsesTheDictionary() {
        #expect(DefaultPrompt.text.contains("{{dictionary}}"))
    }

    @Test func appleModelNames() {
        #expect(Transcriber.AppleModel("apple") == .speech)
        #expect(Transcriber.AppleModel("apple/speech") == .speech)
        #expect(Transcriber.AppleModel("apple/dictation") == .dictation)
        #expect(Transcriber.AppleModel("openai/gpt-4o-transcribe") == nil)
    }
}
