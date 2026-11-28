import AVFoundation
import Foundation
import Testing

/// Audio files for tests, written to the temporary directory.
enum TestAudio {
    /// Writes `samples` to a 16-bit mono WAV file, the format Recorder writes.
    static func wav(_ samples: [Float], sampleRate: Double = 16_000) throws -> URL {
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
    static func noise(db: Double, seconds: Double = 2, sampleRate: Double = 16_000) -> [Float] {
        // Uniform noise in -a...a has an RMS of a / √3.
        let amplitude = Float(pow(10, db / 20) * 3.0.squareRoot())
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -amplitude...amplitude, using: &generator) }
    }

    /// A clip of `say` speaking `text`, as `logos transcribe` would get it.
    static func speech(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "logos-test-\(UUID().uuidString).wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)
        return url
    }
}
