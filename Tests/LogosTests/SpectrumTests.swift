import AVFoundation
import Foundation
import Testing
@testable import Logos

@Suite struct SpectrumTests {
    private func tone(_ hz: Double, sampleRate: Double, count: Int = 4096, amplitude: Float = 0.25) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
    }

    private func bands(_ samples: [Float], sampleRate: Double) -> [Double] {
        let spectrum = Spectrum(sampleRate: sampleRate)
        return samples.withUnsafeBufferPointer { spectrum.process($0) }
    }

    private func loudest(_ levels: [Double]) -> Int {
        levels.indices.max { levels[$0] < levels[$1] }!
    }

    // Catches a wrong bin-to-band mapping. Bands run from 80 Hz to 8 kHz on a log
    // scale, so 1 kHz falls in band 10 of 0–19.
    @Test func toneLightsItsOwnBand() {
        let levels = bands(tone(1000, sampleRate: 48_000), sampleRate: 48_000)
        #expect(levels.count == Spectrum.bandCount)
        #expect(loudest(levels) == 10)
        #expect(levels[0] < 0.2 && levels[19] < 0.2)
    }

    // Catches bands reversed, so low pitches would draw on the right.
    @Test func lowPitchesAreOnTheLeft() {
        let low = loudest(bands(tone(200, sampleRate: 48_000), sampleRate: 48_000))
        let high = loudest(bands(tone(4000, sampleRate: 48_000), sampleRate: 48_000))
        #expect(low < high)
    }

    @Test func silenceIsFlat() {
        let levels = bands([Float](repeating: 0, count: 4096), sampleRate: 48_000)
        #expect(levels.allSatisfy { $0 == 0 })
    }

    // Catches bands past the Nyquist frequency on a 16 kHz input such as a
    // Bluetooth headset, which would index past the FFT's output.
    @Test func lowSampleRateStaysInRange() {
        let levels = bands(tone(3000, sampleRate: 16_000, count: 512), sampleRate: 16_000)
        #expect(levels.count == Spectrum.bandCount)
        #expect(levels.allSatisfy { (0...1).contains($0) })
    }

    // Catches small buffers being analyzed alone instead of as part of a rolling window.
    @Test func smallBuffersAccumulate() {
        let spectrum = Spectrum(sampleRate: 48_000)
        let samples = tone(1000, sampleRate: 48_000)
        var levels: [Double] = []
        for start in stride(from: 0, to: samples.count, by: 256) {
            levels = samples[start..<start + 256].withUnsafeBufferPointer { spectrum.process($0) }
        }
        #expect(loudest(levels) == 10)
    }
}

@Suite struct OverlayLevelTests {
    // Catches bars that drop straight to zero, or that never fall, once a sound stops.
    @Test func barsRiseAtOnceAndFadeWithinHalfASecond() {
        let model = OverlayModel()
        var loud = [Double](repeating: 0, count: Spectrum.bandCount)
        loud[3] = 1
        model.update(loud)
        #expect(model.levels[3] == 1)

        let quiet = [Double](repeating: 0, count: Spectrum.bandCount)
        model.update(quiet)
        #expect(model.levels[3] > 0.5)
        for _ in 0..<15 { model.update(quiet) } // half a second at 30 frames a second
        #expect(model.levels[3] < 0.1)
    }
}

@Suite struct RecorderTests {
    // Catches dropped or partial buffers, and a file left unreadable because it was
    // never closed.
    @Test func writesEveryFrameToAReadableFile() throws {
        let recorder = try Recorder(sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: recorder.url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000)!
        buffer.frameLength = 1000
        for _ in 0..<5 { recorder.append(buffer) }
        recorder.stop()
        recorder.append(buffer) // after stop, ignored

        let file = try AVAudioFile(forReading: recorder.url)
        #expect(file.length == 5000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.sampleRate == 48_000)
    }
}
