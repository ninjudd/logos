import AVFoundation

/// How loud a recording gets, so Logos can skip transcribing one with no speech
/// in it. Whisper models given silence tend to answer with the end of their
/// `prompt`, which ends with the dictionary, so a silent hold would paste a
/// dictionary word.
enum Loudness {
    /// The length of each window that `peakDB(of:)` measures. Fifty milliseconds is
    /// short enough to catch a single short word, and long enough that a click
    /// counts for less than a word.
    static let window = 0.05
    /// The level that `peakDB(of:)` reports for digital silence, which has no level
    /// in decibels. A 16-bit file whose every sample is one step above zero
    /// measures -90 dBFS, so only near-zero audio meets this floor.
    static let floorDB = -100.0

    /// The RMS level of the loudest window in the audio file at `url`, across all
    /// of its channels, in dB relative to full scale (dBFS). Never below `floorDB`.
    static func peakDB(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let size = AVAudioFrameCount(max(1, Int(format.sampleRate * window)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size) else {
            throw LogosError("Couldn't read \(url.lastPathComponent)")
        }
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: size)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            var sum: Float = 0
            for c in 0..<Int(format.channelCount) {
                for i in 0..<frames { sum += channels[c][i] * channels[c][i] }
            }
            peak = max(peak, sum / Float(frames * Int(format.channelCount)))
        }
        return decibels(meanSquare: peak)
    }

    /// Whether a recording whose loudest window is `level` dBFS is too quiet to
    /// hold speech. A threshold at or below `floorDB` treats nothing as silent.
    static func isSilent(_ level: Double, threshold: Double) -> Bool {
        level < threshold
    }

    private static func decibels(meanSquare: Float) -> Double {
        guard meanSquare > 0 else { return floorDB }
        return max(floorDB, 10 * log10(Double(meanSquare)))
    }
}
