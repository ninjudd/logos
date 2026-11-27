import AVFoundation

/// Records the microphone to a temporary mono WAV file and measures its spectrum
/// as it goes. It's started, stopped, and discarded on the app's audio queue and
/// read from the main thread; the state both touch is behind `lock`.
final class Recorder: @unchecked Sendable {
    let url: URL
    private var engine: AVAudioEngine?
    private let file: AVAudioFile
    private let monoFormat: AVAudioFormat
    private let analyzer: Spectrum
    private let lock = NSLock()
    private var bands = [Double](repeating: 0, count: Spectrum.bandCount)
    private var closed = false

    init(sampleRate: Double) throws {
        url = FileManager.default.temporaryDirectory.appending(path: "logos-\(UUID().uuidString).wav")
        monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        analyzer = Spectrum(sampleRate: sampleRate)
    }

    /// Starts recording from the microphone `inputDevice` names. If that device
    /// can't be selected, it records from macOS's default input instead of not at all.
    static func start(inputDevice: String) throws -> Recorder {
        let engine = AVAudioEngine()
        if let device = AudioInput.resolve(inputDevice, among: AudioInput.devices()) {
            do {
                try AudioInput.select(device, for: engine)
            } catch {
                NSLog("Logos: %@; recording from the default input", error.localizedDescription)
            }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw LogosError("No microphone available. Check microphone access.")
        }
        let recorder = try Recorder(sampleRate: format.sampleRate)
        // Deprecated in macOS 27 in favor of a throwing variant that macOS 26 lacks.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak recorder] buffer, _ in
            recorder?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            recorder.discard()
            throw LogosError("Couldn't start recording: \(error.localizedDescription)")
        }
        recorder.engine = engine
        return recorder
    }

    /// Writes the first channel of a buffer to the file and updates the spectrum.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        if let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) {
            mono.frameLength = buffer.frameLength
            mono.floatChannelData![0].update(from: channels[0], count: frames)
            try? file.write(from: mono)
        }
        bands = analyzer.process(UnsafeBufferPointer(start: channels[0], count: frames))
    }

    /// Loudness per frequency band, low to high, each from 0 to 1.
    var spectrum: [Double] {
        lock.withLock { bands }
    }

    /// Stops recording and finishes the file so it can be read.
    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lock.withLock {
            if !closed {
                closed = true
                file.close()
            }
        }
    }

    func discard() {
        stop()
        try? FileManager.default.removeItem(at: url)
    }
}
