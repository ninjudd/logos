import Accelerate

/// Turns a stream of audio samples into loudness per frequency band, from low to
/// high, for the overlay. Bands are spaced evenly in octaves across the range of
/// the human voice.
final class Spectrum {
    static let bandCount = 20

    private let size = 2048
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var samples: [Float]
    /// FFT bins that fall in each band, and each band's correction in dB.
    private let bands: [(bins: Range<Int>, tilt: Double)]

    // Loudness range mapped onto the bar height, in dB relative to full scale.
    private let floorDB = -85.0
    private let ceilingDB = -30.0
    /// Speech gets quieter as pitch rises, so lift higher bands by this much per octave.
    private let tiltPerOctave = 3.0

    init(sampleRate: Double, bandCount: Int = Spectrum.bandCount, lowHz: Double = 80, highHz: Double = 8000) {
        fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        samples = [Float](repeating: 0, count: size)

        let binHz = sampleRate / Double(size)
        let top = min(highHz, sampleRate / 2 * 0.95)
        let tilt = tiltPerOctave
        bands = (0..<bandCount).map { i in
            let lo = lowHz * pow(top / lowHz, Double(i) / Double(bandCount))
            let hi = lowHz * pow(top / lowHz, Double(i + 1) / Double(bandCount))
            let first = max(1, Int((lo / binHz).rounded()))
            let last = max(first + 1, Int((hi / binHz).rounded()))
            return (first..<min(last, 1024), tilt * log2(sqrt(lo * hi) / 500))
        }
    }

    /// Adds new samples and returns each band's level from 0 to 1, measured over
    /// the most recent 2048 samples.
    func process(_ input: UnsafeBufferPointer<Float>) -> [Double] {
        if input.count >= size {
            samples = Array(input.suffix(size))
        } else {
            samples.removeFirst(input.count)
            samples.append(contentsOf: input)
        }
        let windowed = vDSP.multiply(samples, window)

        let half = size / 2
        var inReal = [Float](repeating: 0, count: half)
        var inImag = [Float](repeating: 0, count: half)
        var outReal = [Float](repeating: 0, count: half)
        var outImag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)

        inReal.withUnsafeMutableBufferPointer { inR in
            inImag.withUnsafeMutableBufferPointer { inI in
                outReal.withUnsafeMutableBufferPointer { outR in
                    outImag.withUnsafeMutableBufferPointer { outI in
                        var packed = DSPSplitComplex(realp: inR.baseAddress!, imagp: inI.baseAddress!)
                        windowed.withUnsafeBufferPointer { w in
                            w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &packed, 1, vDSP_Length(half))
                            }
                        }
                        var spectrum = DSPSplitComplex(realp: outR.baseAddress!, imagp: outI.baseAddress!)
                        fft.forward(input: packed, output: &spectrum)
                        vDSP.squareMagnitudes(spectrum, result: &power)
                    }
                }
            }
        }

        // A full-scale sine wave comes out of the FFT with power of about size².
        let scale = Double(size) * Double(size)
        return bands.map { band in
            var sum: Float = 0
            for bin in band.bins { sum += power[bin] }
            let mean = Double(sum) / Double(band.bins.count) / scale
            let db = 10 * log10(mean + 1e-12) + band.tilt
            return min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
        }
    }
}
