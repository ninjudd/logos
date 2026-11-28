import Foundation
import Testing
@testable import Logos

/// Responses from Groq's /audio/transcriptions with `response_format=verbose_json`,
/// for clips that `say` and a noise generator made. The noise clip is room noise,
/// a breath-like swell, and a click, whose loudest 50 ms measures -37 dBFS.
/// Groq's request IDs are left out. Most come from hints that end with a word,
/// which a model echoes most readily. The backstop still has to catch an echo
/// of a hint that ends with "…", since a model can repeat any run of it.
enum GroqFixtures {
    /// The prompt for `turboNoiseLastWord`.
    static let fourWordHint = "Vocabulary: alpha, bravo, charlie, Zanzibar."
    /// The prompt for the `ellipsis` fixtures, as `Vocabulary.transcriptionHint` writes it.
    static let ellipsisHint = "Vocabulary: alpha, bravo, charlie, Zanzibar. …"
    /// The prompt for every other fixture.
    static let threeWordHint = "Vocabulary: alpha, bravo, Zanzibar."

    /// whisper-large-v3-turbo, the noise clip, with `ellipsisHint`: the hint's "…".
    static let turboNoiseEllipsis = #"""
    {"task":"transcribe","language":"English","duration":1.5,"text":" …","segments":[{"id":0,"seek":0,"start":0,"end":1.5,"text":" …","tokens":[50365,5799,50440],"temperature":0,"avg_logprob":-0.43306875,"compression_ratio":0.33333334,"no_speech_prob":0}]}
    """#

    /// whisper-large-v3-turbo, `say` speaking the hint's last word, with `ellipsisHint`.
    static let turboWordEllipsis = #"""
    {"task":"transcribe","language":"English","duration":0.936500032,"text":" Zanzibar.","segments":[{"id":0,"seek":0,"start":0,"end":1,"text":" Zanzibar.","tokens":[50365,1176,3910,897,289,13,50415],"temperature":0,"avg_logprob":-0.3576032,"compression_ratio":0.5555556,"no_speech_prob":0}]}
    """#

    /// whisper-large-v3-turbo, the noise clip: the hint's last word, and a
    /// no_speech_prob of 0.
    static let turboNoiseLastWord = #"""
    {"task":"transcribe","language":"English","duration":1.5,"text":" Zanzibar.","segments":[{"id":0,"seek":0,"start":0,"end":1.5,"text":" Zanzibar.","tokens":[50365,1176,3910,897,289,13,50440],"temperature":0,"avg_logprob":-0.55180484,"compression_ratio":0.5555556,"no_speech_prob":0}]}
    """#

    /// whisper-large-v3-turbo, the noise clip: the hint's first word.
    static let turboNoiseFirstWord = #"""
    {"task":"transcribe","language":"English","duration":1.5,"text":" Vocabulary.","segments":[{"id":0,"seek":0,"start":0,"end":1.5,"text":" Vocabulary.","tokens":[50365,691,905,19189,13,50440],"temperature":0,"avg_logprob":-1.1639167,"compression_ratio":0.6,"no_speech_prob":0}]}
    """#

    /// whisper-large-v3, the noise clip: a stock phrase, with a no_speech_prob
    /// below Whisper's 0.6.
    static let largeNoiseThankYou = #"""
    {"task":"transcribe","language":"English","duration":1.5,"text":" Thank you.","segments":[{"id":0,"seek":0,"start":0,"end":1.5,"text":" Thank you.","tokens":[50365,1044,291,13,50440],"temperature":0,"avg_logprob":-0.69865376,"compression_ratio":0.57894737,"no_speech_prob":0.43408203}]}
    """#

    /// whisper-large-v3, two seconds of -38 dBFS white noise: punctuation only.
    static let largeHissPeriod = #"""
    {"task":"transcribe","language":"English","duration":2,"text":" .","segments":[{"id":0,"seek":0,"start":0,"end":2,"text":" .","tokens":[50365,2411,50465],"temperature":0,"avg_logprob":-0.5940033,"compression_ratio":0.2,"no_speech_prob":0.14440918}]}
    """#

    /// whisper-large-v3-turbo, `say` speaking a sentence, -12 dBFS.
    static let turboSpeech = #"""
    {"task":"transcribe","language":"English","duration":3.074687488,"text":" Please send the deployment notes to the team before launch.","segments":[{"id":0,"seek":0,"start":0,"end":2.8799999,"text":" Please send the deployment notes to the team before launch.","tokens":[50365,2555,2845,264,19317,5570,281,264,1469,949,4025,13,50509],"temperature":0,"avg_logprob":-0.23014091,"compression_ratio":0.95238096,"no_speech_prob":0}]}
    """#

    /// whisper-large-v3-turbo, `say` speaking the hint's last word, -13 dBFS.
    static let turboWord = #"""
    {"task":"transcribe","language":"English","duration":0.936500032,"text":" Zanzibar.","segments":[{"id":0,"seek":0,"start":0,"end":1,"text":" Zanzibar.","tokens":[50365,1176,3910,897,289,13,50415],"temperature":0,"avg_logprob":-0.28163642,"compression_ratio":0.5555556,"no_speech_prob":0}]}
    """#

    static func response(_ json: String) throws -> NoSpeech.Response {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return try #require(NoSpeech.Response(json: object))
    }
}

@Suite struct NoSpeechTests {
    private let threshold = Config().silenceThresholdDB
    /// The noise clip's level, which is above the silence threshold.
    private let breath = -37.3

    private func filter(_ json: String, hint: String = GroqFixtures.threeWordHint, peakDB: Double?) throws -> NoSpeech.Transcript {
        NoSpeech.filter(try GroqFixtures.response(json), hint: hint, peakDB: peakDB, silenceThresholdDB: threshold)
    }

    // Catches the segments' fields going unread, which would leave the
    // no-speech check nothing to check.
    @Test func readsGroqVerboseJSON() throws {
        let response = try GroqFixtures.response(GroqFixtures.largeNoiseThankYou)
        #expect(response.text == " Thank you.")
        #expect(response.segments == [NoSpeech.Segment(text: " Thank you.", noSpeechProb: 0.43408203, avgLogprob: -0.69865376)])
        #expect(response.noSpeechProb == 0.43408203)
        // A no_speech_prob of 0 arrives as an integer.
        #expect(try GroqFixtures.response(GroqFixtures.turboNoiseLastWord).segments?.first?.noSpeechProb == 0)
    }

    // Catches a `json` response, which has no segments, failing to transcribe.
    @Test func readsPlainJSON() throws {
        let response = try GroqFixtures.response(#"{"text":" Hello there."}"#)
        #expect(response.segments == nil)
        #expect(response.speech == "Hello there.")
        #expect(NoSpeech.Response(json: ["segments": []]) == nil)
    }

    // Catches a rule that differs from Whisper's reference decoder: a segment
    // is silent when no_speech_prob is above 0.6 and avg_logprob isn't above -1.
    @Test func segmentRuleMatchesWhisper() {
        func silent(_ noSpeech: Double?, _ logprob: Double?) -> Bool {
            NoSpeech.Segment(text: "x", noSpeechProb: noSpeech, avgLogprob: logprob).isSilent
        }
        #expect(silent(0.9, -1.5))
        #expect(silent(0.61, -1.0))
        #expect(!silent(0.6, -1.5))
        #expect(!silent(0.9, -0.99))
        #expect(!silent(nil, -1.5))
        #expect(!silent(0.9, nil))
    }

    // Catches a silent segment's text reaching the paste, or a kept segment's
    // text going missing. The response is made up: Groq returned no silent
    // segment for any test clip.
    @Test func dropsOnlySilentSegments() {
        let response = NoSpeech.Response(text: " Meet at four. Thank you. Bring slides.", segments: [
            NoSpeech.Segment(text: " Meet at four.", noSpeechProb: 0.01, avgLogprob: -0.2),
            NoSpeech.Segment(text: " Thank you.", noSpeechProb: 0.8, avgLogprob: -1.2),
            NoSpeech.Segment(text: " Bring slides.", noSpeechProb: 0.02, avgLogprob: -0.3),
        ])
        #expect(response.speech == "Meet at four. Bring slides.")
        let transcript = NoSpeech.filter(response, hint: "", peakDB: -20, silenceThresholdDB: threshold)
        #expect(transcript == NoSpeech.Transcript(
            text: "Meet at four. Bring slides.",
            dropped: NoSpeech.Dropped(text: "Meet at four. Thank you. Bring slides.", reason: .noSpeech)))
    }

    // Catches a transcript that Whisper marks silent throughout being pasted.
    @Test func dropsAnAllSilentTranscript() {
        let response = NoSpeech.Response(text: " Thank you.", segments: [
            NoSpeech.Segment(text: " Thank you.", noSpeechProb: 0.9, avgLogprob: -1.4),
        ])
        let transcript = NoSpeech.filter(response, hint: "", peakDB: -20, silenceThresholdDB: threshold)
        #expect(transcript == NoSpeech.Transcript(text: "", dropped: NoSpeech.Dropped(text: "Thank you.", reason: .noSpeech)))
    }

    // Catches the bug: a breath louder than the silence threshold went to
    // whisper-large-v3-turbo, which answered with the last word of the
    // dictionary hint, and Logos pasted it.
    @Test func dropsTheHintsLastWordFromABreath() throws {
        let transcript = try filter(GroqFixtures.turboNoiseLastWord, hint: GroqFixtures.fourWordHint, peakDB: breath)
        #expect(transcript == NoSpeech.Transcript(text: "", dropped: NoSpeech.Dropped(text: "Zanzibar.", reason: .echo)))
    }

    // Catches an echo of a word other than the hint's last being pasted.
    @Test func dropsTheHintsFirstWordFromABreath() throws {
        #expect(try filter(GroqFixtures.turboNoiseFirstWord, peakDB: breath).text == "")
    }

    // Catches Whisper's stock answer to noise being pasted.
    @Test func dropsAStockPhraseFromABreath() throws {
        #expect(try filter(GroqFixtures.largeNoiseThankYou, peakDB: breath).text == "")
    }

    // Catches a lone "." from noise being pasted.
    @Test func dropsPunctuationFromNoise() throws {
        #expect(try filter(GroqFixtures.largeHissPeriod, peakDB: -37.6).text == "")
    }

    // Catches the "…" that ends the hint being pasted, from a breath or from
    // noise loud enough to pass for speech.
    @Test func dropsTheHintsEllipsisAtAnyLevel() throws {
        for peakDB in [breath, -15, nil] {
            let transcript = try filter(GroqFixtures.turboNoiseEllipsis, hint: GroqFixtures.ellipsisHint, peakDB: peakDB)
            #expect(transcript == NoSpeech.Transcript(text: "", dropped: NoSpeech.Dropped(text: "…", reason: .echo)))
        }
    }

    // Catches the ellipsis ending keeping the hint's last word from being
    // transcribed when it is said.
    @Test func keepsASpokenWordAfterTheEllipsis() throws {
        let transcript = try filter(GroqFixtures.turboWordEllipsis, hint: GroqFixtures.ellipsisHint, peakDB: -12.8)
        #expect(transcript == NoSpeech.Transcript(text: "Zanzibar."))
    }

    // Catches a stock phrase that Whisper scored as borderline no speech being
    // pasted because the noise was loud.
    @Test func dropsALoudEchoThatWhisperDoubts() throws {
        #expect(try filter(GroqFixtures.largeNoiseThankYou, peakDB: -20).text == "")
    }

    // Catches the backstop swallowing a dictionary word said on its own at a
    // speaking level.
    @Test func keepsASpokenDictionaryWord() throws {
        let transcript = try filter(GroqFixtures.turboWord, peakDB: -12.8)
        #expect(transcript == NoSpeech.Transcript(text: "Zanzibar."))
    }

    // Catches speech being dropped, at a speaking level and at a quiet one.
    @Test func keepsSpeech() throws {
        let text = "Please send the deployment notes to the team before launch."
        #expect(try filter(GroqFixtures.turboSpeech, peakDB: -11.7) == NoSpeech.Transcript(text: text))
        #expect(try filter(GroqFixtures.turboSpeech, peakDB: -40) == NoSpeech.Transcript(text: text))
    }

    // Catches the silence setting failing to turn the backstop off, and a
    // recording Logos couldn't measure counting as quiet.
    @Test func backstopNeedsAQuietMeasuredRecording() throws {
        let response = try GroqFixtures.response(GroqFixtures.turboNoiseLastWord)
        let hint = GroqFixtures.fourWordHint
        #expect(NoSpeech.filter(response, hint: hint, peakDB: breath, silenceThresholdDB: Loudness.floorDB).text == "Zanzibar.")
        #expect(NoSpeech.filter(response, hint: hint, peakDB: nil, silenceThresholdDB: threshold).text == "Zanzibar.")
        #expect(NoSpeech.filter(response, hint: hint, peakDB: -30.1, silenceThresholdDB: threshold).text == "")
        #expect(NoSpeech.filter(response, hint: hint, peakDB: -30, silenceThresholdDB: threshold).text == "Zanzibar.")
    }

    // Catches the echo rule matching words that aren't a run of the hint, or
    // missing one because of case, punctuation, or spacing.
    @Test func echoIsARunOfTheHintsWords() {
        let hint = "Spell names right. Vocabulary: alpha, Bravo, gpt-4o, Zanzibar."
        for echo in ["Zanzibar.", "zanzibar", "GPT-4o, Zanzibar", "Vocabulary.", "alpha bravo", "right. Vocabulary:", "…", ""] {
            #expect(NoSpeech.isEcho(echo, hint: hint), "\(echo)")
        }
        for speech in ["alpha Zanzibar", "Zanzi", "Zanzibar is far", "send it"] {
            #expect(!NoSpeech.isEcho(speech, hint: hint), "\(speech)")
        }
        #expect(!NoSpeech.isEcho("Zanzibar", hint: ""))
    }

    // Catches Whisper's well-known answers to silence going unrecognized.
    @Test func echoIncludesStockPhrases() {
        for phrase in ["Thank you.", "Thanks for watching!", "you", "Uh..."] {
            #expect(NoSpeech.isEcho(phrase, hint: ""), "\(phrase)")
        }
        #expect(!NoSpeech.isEcho("Thank you for the notes.", hint: ""))
    }

    // Catches asking a model for verbose_json when it accepts only json, or
    // not asking a Whisper model for it.
    @Test func asksWhisperModelsForSegments() {
        for model in ["whisper-large-v3-turbo", "whisper-large-v3", "whisper-1", "distil-whisper-large-v3-en"] {
            #expect(Transcriber.asksForSegments(model), "\(model)")
        }
        for model in ["gpt-4o-transcribe", "gpt-4o-mini-transcribe"] {
            #expect(!Transcriber.asksForSegments(model), "\(model)")
        }
    }

    // MARK: Through the pipeline

    private func config(_ api: StubTranscriptionAPI, model: String = "whisper-large-v3-turbo") -> Config {
        var config = Config()
        config.providers["stub"] = Config.Provider(api: "openai", baseURL: api.baseURL)
        config.transcription.model = "stub/\(model)"
        config.cleanup.enabled = false
        config.saveHistory = false
        return config
    }

    private let vocabulary = ["alpha", "bravo", "charlie", "Zanzibar"].map { Vocabulary.Entry(term: $0) }

    // Catches the bug end to end: a breath above the silence threshold pasted
    // the last word of the dictionary hint.
    @Test func pipelineDropsABreathsEcho() async throws {
        let api = StubTranscriptionAPI { _ in (200, GroqFixtures.turboNoiseLastWord) }
        let url = try TestAudio.wav(TestAudio.noise(db: -37))
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await Pipeline.run(audio: url, config: config(api), prompt: "", vocabulary: vocabulary, app: "Test")
        #expect(api.formats == ["verbose_json"])
        #expect(outcome.raw == "")
        #expect(outcome.text == "")
        #expect(outcome.warning == "No speech detected")
        #expect(outcome.dropped == NoSpeech.Dropped(text: "Zanzibar.", reason: .echo))
    }

    // Catches the same answer being dropped when the recording is loud enough
    // to be a word you said.
    @Test func pipelineKeepsASpokenWord() async throws {
        let api = StubTranscriptionAPI { _ in (200, GroqFixtures.turboWord) }
        let url = try TestAudio.speech("Zanzibar")
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await Pipeline.run(audio: url, config: config(api), prompt: "", vocabulary: vocabulary, app: "Test")
        #expect(outcome.raw == "Zanzibar.")
        #expect(outcome.dropped == nil)
        #expect(outcome.warning == nil)
    }

    // Catches a server that rejects verbose_json breaking transcription.
    @Test func pipelineFallsBackToJSON() async throws {
        let api = StubTranscriptionAPI { format in
            format == "verbose_json"
                ? (400, #"{"error":{"message":"response_format 'verbose_json' is not supported"}}"#)
                : (200, #"{"text":" Hello there."}"#)
        }
        let url = try TestAudio.speech("hello there")
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await Pipeline.run(audio: url, config: config(api), prompt: "", vocabulary: [], app: "Test")
        #expect(api.formats == ["verbose_json", "json"])
        #expect(outcome.raw == "Hello there.")
    }

    // Catches a failure other than the format being retried, which would hide
    // the API's error behind a second request.
    @Test func pipelineReportsOtherErrors() async throws {
        let api = StubTranscriptionAPI { _ in (401, #"{"error":{"message":"Invalid API Key"}}"#) }
        let url = try TestAudio.speech("hello there")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: LogosError.self) {
            try await Pipeline.run(audio: url, config: config(api), prompt: "", vocabulary: [], app: "Test")
        }
        #expect(api.formats == ["verbose_json"])
    }

    // Catches a model that accepts only json being sent verbose_json.
    @Test func pipelineSendsJSONToOtherModels() async throws {
        let api = StubTranscriptionAPI { _ in (200, #"{"text":" Hello there."}"#) }
        let url = try TestAudio.speech("hello there")
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await Pipeline.run(audio: url, config: config(api, model: "gpt-4o-transcribe"),
                                             prompt: "", vocabulary: [], app: "Test")
        #expect(api.formats == ["json"])
        #expect(outcome.raw == "Hello there.")
    }
}
