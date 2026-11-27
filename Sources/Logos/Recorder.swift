import AVFoundation

/// Records the microphone to a temporary 16 kHz mono WAV file.
final class Recorder {
    private let recorder: AVAudioRecorder
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "logos-\(UUID().uuidString).wav")
        recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        recorder.isMeteringEnabled = true
    }

    func start() throws {
        guard recorder.record() else { throw LogosError("Couldn't start recording. Check microphone access.") }
    }

    func stop() {
        recorder.stop()
    }

    func discard() {
        recorder.stop()
        try? FileManager.default.removeItem(at: url)
    }

    /// Input loudness from 0 to 1.
    var level: Double {
        recorder.updateMeters()
        let db = Double(recorder.averagePower(forChannel: 0))
        return min(1, max(0, (db + 50) / 45))
    }
}
