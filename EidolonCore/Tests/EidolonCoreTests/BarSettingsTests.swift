import XCTest
@testable import EidolonCore

/// The bar's settings: two volumes in tenths, the slider's geometry and what a stored record
/// is read as (upstream `lib/barSettings.ts`).
final class BarSettingsTests: XCTestCase {
    func testATenthIsTenPercentAndFullIsTheFileAsItIs() {
        XCTAssertEqual(BarSettings.gain(of: 0), 0)
        XCTAssertEqual(BarSettings.gain(of: 3), 0.3, accuracy: 0.000_001)
        XCTAssertEqual(BarSettings.gain(of: 10), 1)
    }

    func testPlusAndMinusStepOneTenthAndStopAtTheEnds() {
        XCTAssertEqual(BarSettings.stepVolume(5, by: 1), 6)
        XCTAssertEqual(BarSettings.stepVolume(5, by: -1), 4)
        XCTAssertEqual(BarSettings.stepVolume(10, by: 1), 10)
        XCTAssertEqual(BarSettings.stepVolume(0, by: -1), 0)
    }

    func testTheKnobGoesFromTheGroovesLeftToItsRight() {
        let slider = BarSettings.Slider.self
        XCTAssertEqual(BarSettings.knobX(0), slider.groove)
        XCTAssertEqual(BarSettings.knobX(10), slider.groove + slider.grooveWidth - slider.knobWidth)
        XCTAssertEqual(BarSettings.knobX(5), slider.groove + 49)
    }

    func testAPointOnTheSliderIsTheNearestTenthWithTheKnobCentredOnIt() {
        for steps in 0...10 {
            let centre = BarSettings.knobX(steps) + BarSettings.Slider.knobWidth / 2
            XCTAssertEqual(BarSettings.volumeAt(x: centre), steps, "\(steps)")
        }
        XCTAssertEqual(BarSettings.volumeAt(x: BarSettings.knobX(4) + 6), 4)
        XCTAssertEqual(BarSettings.volumeAt(x: BarSettings.knobX(4) + 8), 5)
    }

    func testPastTheGrooveItStopsAtEitherEnd() {
        XCTAssertEqual(BarSettings.volumeAt(x: 0), 0)
        XCTAssertEqual(BarSettings.volumeAt(x: -50), 0)
        XCTAssertEqual(BarSettings.volumeAt(x: 139), 10)
        XCTAssertEqual(BarSettings.volumeAt(x: 400), 10)
    }

    func testNothingKeptIsFullVolumesAndScanlinesOff() {
        XCTAssertEqual(BarSettings(stored: nil), .default)
    }

    func testWhatWasKeptIsReadBack() {
        let mine = BarSettings.Stored(music: 3, sfx: 0, scanlines: true)

        XCTAssertEqual(BarSettings(stored: mine), BarSettings(music: 3, sfx: 0, scanlines: true))
    }

    func testWhatCannotBeReadIsTheDefaultAndTheRestKept() {
        XCTAssertEqual(
            BarSettings(stored: .init(music: 11, sfx: 2, scanlines: false)),
            BarSettings(music: 10, sfx: 2, scanlines: false)
        )
        XCTAssertEqual(
            BarSettings(stored: .init(music: -1, sfx: 4, scanlines: true)),
            BarSettings(music: 10, sfx: 4, scanlines: true)
        )
    }
}
