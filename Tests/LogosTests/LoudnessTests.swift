import Foundation
import Testing
@testable import Logos

@Suite struct LoudnessTests {
    private let threshold = Config().silenceThresholdDB

    // Catches a hold with nothing said reaching a Whisper model, which answers
    // silence with a word from the dictionary.
    @Test func digitalSilenceIsBelowTheDefault() throws {
        let url = try TestAudio.wav([Float](repeating: 0, count: 32_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let level = try Loudness.peakDB(of: url)
        #expect(level == Loudness.floorDB)
        #expect(Loudness.isSilent(level, threshold: threshold))
    }

    // Catches room noise counting as speech. A quiet room into a laptop
    // microphone measures about -60 to -50 dBFS.
    @Test func roomNoiseIsBelowTheDefault() throws {
        for db in [-65.0, -55.0] {
            let url = try TestAudio.wav(TestAudio.noise(db: db))
            defer { try? FileManager.default.removeItem(at: url) }
            let level = try Loudness.peakDB(of: url)
            #expect(abs(level - db) < 1.5, "noise at \(db) dBFS measured \(level)")
            #expect(Loudness.isSilent(level, threshold: threshold))
        }
    }

    // Catches speech being dropped as silence, including a one-word answer.
    @Test func speechIsAboveTheDefault() throws {
        for text in ["um so I think we should meet at three, no wait, at four", "yes"] {
            let url = try TestAudio.speech(text)
            defer { try? FileManager.default.removeItem(at: url) }
            let level = try Loudness.peakDB(of: url)
            #expect(!Loudness.isSilent(level, threshold: threshold), "\"\(text)\" measured \(level) dBFS")
        }
    }

    // Catches a loud word in a long quiet clip being averaged away, which would
    // drop a short answer said after a pause.
    @Test func oneLoudWindowIsEnough() throws {
        var samples = TestAudio.noise(db: -60, seconds: 5)
        let loud = TestAudio.noise(db: -20, seconds: 0.1)
        samples.replaceSubrange(40_000..<40_000 + loud.count, with: loud)
        let url = try TestAudio.wav(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(abs(try Loudness.peakDB(of: url) - -20) < 1.5)
    }

    // Catches the setting failing to turn the check off.
    @Test func thresholdAtTheFloorTreatsNothingAsSilent() {
        #expect(!Loudness.isSilent(Loudness.floorDB, threshold: Loudness.floorDB))
        #expect(Loudness.isSilent(-50, threshold: -45))
        #expect(!Loudness.isSilent(-40, threshold: -45))
    }

    /// A config whose speech model names a provider that doesn't exist, so
    /// reaching the model throws instead of calling a network.
    private func unreachable() -> Config {
        var config = Config()
        config.transcription.model = "unreachable/model"
        config.saveHistory = false
        return config
    }

    // Catches Pipeline sending a silent clip to the speech model, which would
    // throw here.
    @Test func pipelineSkipsTranscriptionForSilence() async throws {
        let url = try TestAudio.wav(TestAudio.noise(db: -60))
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await Pipeline.run(audio: url, config: unreachable(), prompt: "", vocabulary: [], app: "Test")
        #expect(outcome.raw == "")
        #expect(outcome.text == "")
        #expect(outcome.warning == "No speech detected")
    }

    // Catches the check dropping speech. The clip reaches the speech model,
    // which throws.
    @Test func pipelineTranscribesSpeech() async throws {
        let url = try TestAudio.speech("hello there")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: LogosError.self) {
            try await Pipeline.run(audio: url, config: unreachable(), prompt: "", vocabulary: [], app: "Test")
        }
    }

    // Catches the setting failing to turn the check off in the pipeline.
    @Test func pipelineTranscribesSilenceWhenTheCheckIsOff() async throws {
        let url = try TestAudio.wav(TestAudio.noise(db: -60))
        defer { try? FileManager.default.removeItem(at: url) }
        var config = unreachable()
        config.silenceThresholdDB = Loudness.floorDB
        await #expect(throws: LogosError.self) {
            try await Pipeline.run(audio: url, config: config, prompt: "", vocabulary: [], app: "Test")
        }
    }
}
