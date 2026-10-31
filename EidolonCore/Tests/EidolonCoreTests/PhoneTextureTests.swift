import Foundation
import XCTest
@testable import EidolonCore

/// 电话质感 (spec #36): the band and the compressor match upstream's parameters, measured
/// on sines rather than on coefficients.
final class PhoneTextureTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let rates = [48_000.0, 44_100.0, 24_000.0, 16_000.0]

    private func sine(
        _ frequency: Double,
        peak: Double,
        seconds: Double = 1,
        sampleRate: Double
    ) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            Float(peak * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    /// The RMS of the part after the filters and compressor have settled, in dBFS.
    private func settledDb(_ samples: [Float], sampleRate: Double) -> Double {
        let start = samples.count / 2
        let tail = samples[start...]
        let rms = sqrt(tail.reduce(0.0) { $0 + Double($1 * $1) } / Double(tail.count))
        return 20 * log10(max(rms, 1e-12))
    }

    private func peak(_ samples: [Float]) -> Double {
        let start = samples.count / 2
        return Double(samples[start...].map { abs($0) }.max() ?? 0)
    }

    func testThePassbandIsLeftAlone() {
        for rate in rates {
            let input = sine(1_000, peak: 0.01, sampleRate: rate)
            let output = PhoneTexture(sampleRate: rate).process(input)
            XCTAssertEqual(
                settledDb(output, sampleRate: rate),
                settledDb(input, sampleRate: rate),
                accuracy: 0.5,
                "1 kHz at \(rate) Hz"
            )
        }
    }

    func testBothEndsOfTheBandAreCut() {
        for rate in rates {
            // 8 kHz is above what a 16 kHz stream can carry; use a high tone it can.
            for frequency in [100.0, min(8_000.0, rate * 0.4)] {
                let input = sine(frequency, peak: 0.01, sampleRate: rate)
                let output = PhoneTexture(sampleRate: rate).process(input)
                let drop = settledDb(output, sampleRate: rate)
                    - settledDb(input, sampleRate: rate)
                XCTAssertLessThanOrEqual(drop, -18, "\(frequency) Hz at \(rate) Hz fell only \(drop) dB")
            }
        }
    }

    func testTheCutoffEdgesSitBelowThePassband() {
        for frequency in [300.0, 3_400.0] {
            let input = sine(frequency, peak: 0.01, sampleRate: sampleRate)
            let output = PhoneTexture(sampleRate: sampleRate).process(input)
            let drop = settledDb(output, sampleRate: sampleRate)
                - settledDb(input, sampleRate: sampleRate)
            XCTAssertLessThan(drop, -2, "\(frequency) Hz should already be falling")
        }
    }

    func testAQuietLineIsNotCompressed() {
        let input = sine(1_000, peak: 0.0316, sampleRate: sampleRate)
        let output = PhoneTexture(sampleRate: sampleRate).process(input)
        XCTAssertEqual(
            settledDb(output, sampleRate: sampleRate),
            settledDb(input, sampleRate: sampleRate),
            accuracy: 0.5
        )
    }

    func testALoudLineIsCompressedThreeToOne() {
        let input = sine(1_000, peak: 0.5, sampleRate: sampleRate)
        let output = PhoneTexture(sampleRate: sampleRate).process(input)
        // −6 dBFS peak comes out at about −18 dBFS, and never above it.
        XCTAssertEqual(20 * log10(max(peak(output), 1e-9)), -18, accuracy: 1.5)
        XCTAssertLessThanOrEqual(peak(output), 0.15)
    }

    func testTheLengthIsKeptAndEverySampleIsFinite() {
        let texture = PhoneTexture(sampleRate: sampleRate)
        let input = sine(440, peak: 0.2, seconds: 0.25, sampleRate: sampleRate)
        let output = texture.process(input)
        XCTAssertEqual(output.count, input.count)
        XCTAssertFalse(output.contains { $0.isNaN || $0.isInfinite })
    }

    func testTheSameSegmentIsProcessedTheSameWay() {
        let texture = PhoneTexture(sampleRate: sampleRate)
        let input = sine(440, peak: 0.2, seconds: 0.25, sampleRate: sampleRate)
        XCTAssertEqual(texture.process(input), texture.process(input))
    }

    func testSilenceStaysSilent() {
        let silence = [Float](repeating: 0, count: 1_000)
        XCTAssertEqual(PhoneTexture(sampleRate: sampleRate).process(silence), silence)
    }

    func testAnEmptySegmentStaysEmpty() {
        XCTAssertEqual(PhoneTexture(sampleRate: sampleRate).process([]), [])
    }
}
