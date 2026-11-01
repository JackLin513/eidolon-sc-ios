import XCTest
@testable import EidolonCore

/// The producer's birthday as settings writes it (spec #55): a day some year has.
final class BirthdayTests: XCTestCase {
    func testDaysEveryYearHasAreValid() {
        XCTAssertTrue(Birthday.valid(month: 1, day: 1))
        XCTAssertTrue(Birthday.valid(month: 2, day: 29))
        XCTAssertTrue(Birthday.valid(month: 12, day: 31))
    }

    func testImpossibleDaysAndMonthsAreNotValid() {
        XCTAssertFalse(Birthday.valid(month: 2, day: 30))
        XCTAssertFalse(Birthday.valid(month: 4, day: 31))
        XCTAssertFalse(Birthday.valid(month: 0, day: 1))
        XCTAssertFalse(Birthday.valid(month: 13, day: 1))
        XCTAssertFalse(Birthday.valid(month: 1, day: 0))
    }
}
