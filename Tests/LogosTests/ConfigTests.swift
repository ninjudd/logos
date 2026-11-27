import Foundation
import Testing
@testable import Logos

@Suite struct ConfigTests {
    private func decode(_ json: String) throws -> Config {
        try Config.decode(Data(json.utf8))
    }

    // Catches a merge that replaces a whole section instead of the keys it names.
    @Test func partialFileKeepsDefaultsInsideSections() throws {
        let config = try decode(#"{"cleanup": {"model": "groq/llama-3.3-70b-versatile"}}"#)
        #expect(config.cleanup.model == "groq/llama-3.3-70b-versatile")
        #expect(config.cleanup.effort == "low")
        #expect(config.cleanup.enabled)
        #expect(config.transcription.model == "apple")
        #expect(config.hotkey == .option)
    }

    @Test func emptyFileIsTheDefaults() throws {
        let config = try decode("{}")
        #expect(config.cleanup.model == Config().cleanup.model)
        #expect(config.keys == Config().keys)
    }

    // Catches a typo in config.json being silently replaced by the default.
    @Test func unknownHotkeyIsAnError() {
        #expect(throws: (any Error).self) { try decode(#"{"hotkey": "fn"}"#) }
    }

    @Test func nonObjectFileIsAnError() {
        #expect(throws: (any Error).self) { try decode("[]") }
    }

    // Catches splitting on the last slash, which breaks OpenRouter's vendor/model ids.
    @Test func resolveSplitsOnTheFirstSlash() throws {
        let model = try Config().resolve("openrouter/anthropic/claude-haiku-5-5")
        #expect(model.provider == "openrouter")
        #expect(model.model == "anthropic/claude-haiku-5-5")
        #expect(model.api == "openai")
        #expect(model.baseURL.absoluteString == "https://openrouter.ai/api/v1")
    }

    @Test func resolveUsesTheProvidersKey() throws {
        var config = Config()
        config.keys["groq"] = "gsk_test"
        #expect(try config.resolve("groq/whisper-large-v3-turbo").apiKey == "gsk_test")
    }

    // Catches the environment fallback reading the wrong variable name.
    @Test func emptyKeyFallsBackToTheEnvironment() throws {
        setenv("LOGOSTEST_API_KEY", "from-env", 1)
        defer { unsetenv("LOGOSTEST_API_KEY") }
        var config = Config()
        config.providers["logostest"] = .init(api: "openai", baseURL: "http://localhost:1/v1")
        #expect(try config.resolve("logostest/m").apiKey == "from-env")
    }

    // Catches built-in providers shadowing the user's own definition.
    @Test func customProviderOverridesBuiltIn() throws {
        var config = Config()
        config.providers["openai"] = .init(api: "openai", baseURL: "http://localhost:8080/v1")
        #expect(try config.resolve("openai/gpt-x").baseURL.absoluteString == "http://localhost:8080/v1")
    }

    @Test func modelWithoutProviderIsAnError() {
        #expect(throws: (any Error).self) { try Config().resolve("claude-opus-5-5") }
    }

    @Test func unknownProviderIsAnError() {
        #expect(throws: (any Error).self) { try Config().resolve("nowhere/model") }
    }

    // Catches whole numbers in extraBody being sent as 0.0, which some APIs reject
    // for integer parameters such as max_tokens.
    @Test func extraBodyKeepsIntegersIntegral() throws {
        let config = try decode(#"{"cleanup": {"extraBody": {"max_tokens": 200, "top_p": 0.5, "stop": ["\n"]}}}"#)
        let body = config.cleanup.extraBody.mapValues(\.foundation)
        #expect(body["max_tokens"] as? Int == 200)
        #expect(body["top_p"] as? Double == 0.5)
        #expect(body["stop"] as? [String] == ["\n"])
    }
}

@Suite struct PromptTests {
    @Test func promptIsTheSystemPromptByDefault() {
        let (system, user) = Cleaner.messages(prompt: "Dictating into {{app}}.", transcript: "um hi", app: "Slack")
        #expect(system == "Dictating into Slack.")
        #expect(user == "<transcript>\num hi\n</transcript>")
    }

    @Test func transcriptPlaceholderMakesOneUserMessage() {
        let (system, user) = Cleaner.messages(prompt: "Fix this for {{app}}: {{transcript}}", transcript: "um hi", app: "Mail")
        #expect(system == nil)
        #expect(user == "Fix this for Mail: um hi")
    }

    // Catches substituting {{app}} after the transcript is inserted, which would
    // rewrite words the user actually said.
    @Test func placeholderTextInTheTranscriptIsLeftAlone() {
        let (_, user) = Cleaner.messages(prompt: "{{transcript}}", transcript: "type {{app}} literally", app: "Terminal")
        #expect(user == "type {{app}} literally")
    }
}
