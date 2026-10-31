import Foundation

/// 电话质感：her voice put through a telephone line before it is played (spec #36,
/// upstream `characterVoice.phoneLine`). Two high-passes at 300 Hz and two low-passes at
/// 3400 Hz, then a soft-knee compressor; the parameters are upstream's, verbatim.
///
/// One instance processes one segment: the filters and the compressor start fresh each
/// time, which is what upstream's continuous stream sounds like with silence between her
/// lines.
public struct PhoneTexture: Sendable {
    static let lowEdge = 300.0
    static let highEdge = 3400.0
    /// Butterworth, as upstream's `Math.SQRT1_2`.
    static let quality = 0.7071067811865476
    static let thresholdDb = -24.0
    static let kneeDb = 12.0
    static let ratio = 3.0
    static let attack = 0.005
    static let release = 0.2

    private let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// The same number of samples in and out, run through the line. Silence stays silence.
    public func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return samples }
        var filters = [
            Biquad.highpass(frequency: Self.lowEdge, quality: Self.quality, sampleRate: sampleRate),
            Biquad.highpass(frequency: Self.lowEdge, quality: Self.quality, sampleRate: sampleRate),
            Biquad.lowpass(frequency: Self.highEdge, quality: Self.quality, sampleRate: sampleRate),
            Biquad.lowpass(frequency: Self.highEdge, quality: Self.quality, sampleRate: sampleRate),
        ]
        var compressor = Compressor(sampleRate: sampleRate)
        var output = [Float](repeating: 0, count: samples.count)
        for index in samples.indices {
            var value = Double(samples[index])
            for filter in filters.indices {
                value = filters[filter].process(value)
            }
            value = compressor.process(value)
            output[index] = Float(value)
        }
        return output
    }
}

/// One RBJ cookbook biquad (direct form I).
private struct Biquad {
    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double
    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    static func highpass(frequency: Double, quality: Double, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = terms(frequency: frequency, quality: quality, sampleRate: sampleRate)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cosine) / 2 / a0,
            b1: -(1 + cosine) / a0,
            b2: (1 + cosine) / 2 / a0,
            a1: -2 * cosine / a0,
            a2: (1 - alpha) / a0
        )
    }

    static func lowpass(frequency: Double, quality: Double, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = terms(frequency: frequency, quality: quality, sampleRate: sampleRate)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 - cosine) / 2 / a0,
            b1: (1 - cosine) / a0,
            b2: (1 - cosine) / 2 / a0,
            a1: -2 * cosine / a0,
            a2: (1 - alpha) / a0
        )
    }

    private static func terms(
        frequency: Double,
        quality: Double,
        sampleRate: Double
    ) -> (cosine: Double, alpha: Double) {
        let omega = 2 * Double.pi * frequency / sampleRate
        return (cos(omega), sin(omega) / (2 * quality))
    }

    private init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}

/// A soft-knee compressor in dB, with upstream's attack and release. No lookahead, so the
/// first few milliseconds of a line are shaped as they are spoken.
private struct Compressor {
    private let attack: Double
    private let release: Double
    private var gainDb = 0.0

    init(sampleRate: Double) {
        attack = exp(-1 / (PhoneTexture.attack * sampleRate))
        release = exp(-1 / (PhoneTexture.release * sampleRate))
    }

    mutating func process(_ x: Double) -> Double {
        let level = 20 * log10(max(abs(x), 1e-9))
        let over = level - PhoneTexture.thresholdDb
        let target: Double
        if over > PhoneTexture.kneeDb / 2 {
            target = over / PhoneTexture.ratio - over
        } else if over > -PhoneTexture.kneeDb / 2 {
            let inside = over + PhoneTexture.kneeDb / 2
            target = (1 / PhoneTexture.ratio - 1)
                * inside * inside / (2 * PhoneTexture.kneeDb)
        } else {
            target = 0
        }
        // From unity, so a segment that starts loud still gets its attack.
        let coefficient = target < gainDb ? attack : release
        gainDb = coefficient * gainDb + (1 - coefficient) * target
        return x * pow(10, gainDb / 20)
    }
}
