import AVFoundation
import Foundation
import Testing
@testable import Logos

@Suite struct LoudnessTests {
    private let threshold = Config().silenceThresholdDB

    /// Writes `samples` to a 16-bit mono WAV file, the format Recorder writes.
    private func wav(_ samples: [Float], sampleRate: Double = 16_000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "logos-test-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample }
        try file.write(from: buffer)
        return url
    }

    /// White noise whose RMS level is `db` dBFS, like a quiet room.
    private func noise(db: Double, seconds: Double = 2, sampleRate: Double = 16_000) -> [Float] {
        // Uniform noise in -a...a has an RMS of a / √3.
        let amplitude = Float(pow(10, db / 20) * 3.0.squareRoot())
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    /// A clip of `say` speaking `text`, as `logos transcribe` would get it.
    private func speech(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "logos-test-\(UUID().uuidString).wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)
        return url
    }

    // Catches a hold with nothing said reaching a Whisper model, which answers
    // silence with a word from the dictionary.
    @Test func digitalSilenceIsBelowTheDefault() throws {
        let url = try wav([Float](repeating: 0, count: 32_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let level = try Loudness.peakDB(of: url)
        #expect(level == Loudness.floorDB)
        #expect(Loudness.isSilent(level, threshold: threshold))
    }

    // Catches room noise counting as speech. A quiet room into a laptop
    // microphone measures about -60 to -50 dBFS.
    @Test func roomNoiseIsBelowTheDefault() throws {
        for db in [-65.0, -55.0] {
            let url = try wav(noise(db: db))
            defer { try? FileManager.default.removeItem(at: url) }
            let level = try Loudness.peakDB(of: url)
            #expect(abs(level - db) < 1.5, "noise at \(db) dBFS measured \(level)")
            #expect(Loudness.isSilent(level, threshold: threshold))
        }
    }

    // Catches speech being dropped as silence, including a one-word answer.
    @Test func speechIsAboveTheDefault() throws {
        for text in ["um so I think we should meet at three, no wait, at four", "yes"] {
            let url = try speech(text)
            defer { try? FileManager.default.removeItem(at: url) }
            let level = try Loudness.peakDB(of: url)
            #expect(!Loudness.isSilent(level, threshold: threshold), "\"\(text)\" measured \(level) dBFS")
        }
    }

    // Catches a loud word in a long quiet clip being averaged away, which would
    // drop a short answer said after a pause.
    @Test func oneLoudWindowIsEnough() throws {
        var samples = noise(db: -60, seconds: 5)
        let loud = noise(db: -20, seconds: 0.1)
        samples.replaceSubrange(40_000..<40_000 + loud.count, with: loud)
        let url = try wav(samples)
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
        let url = try wav(noise(db: -60))
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = try await Pipeline.run(audio: url, config: unreachable(), prompt: "", vocabulary: [], app: "Test")
        #expect(outcome.raw == "")
        #expect(outcome.text == "")
        #expect(outcome.warning == "No speech detected")
    }

    // Catches the check dropping speech. The clip reaches the speech model,
    // which throws.
    @Test func pipelineTranscribesSpeech() async throws {
        let url = try speech("hello there")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: LogosError.self) {
            try await Pipeline.run(audio: url, config: unreachable(), prompt: "", vocabulary: [], app: "Test")
        }
    }

    // Catches the setting failing to turn the check off in the pipeline.
    @Test func pipelineTranscribesSilenceWhenTheCheckIsOff() async throws {
        let url = try wav(noise(db: -60))
        defer { try? FileManager.default.removeItem(at: url) }
        var config = unreachable()
        config.silenceThresholdDB = Loudness.floorDB
        await #expect(throws: LogosError.self) {
            try await Pipeline.run(audio: url, config: config, prompt: "", vocabulary: [], app: "Test")
        }
    }
}
