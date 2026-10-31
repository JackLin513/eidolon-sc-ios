import XCTest
@testable import EidolonCore

/// The roster's pinned and hidden roles (spec #48): pinned first, hidden out of the list,
/// and the count the footer says.
final class RosterTidyTests: XCTestCase {
    private func character(_ id: String) -> CharacterConfig {
        CharacterConfig(id: id, name: id, birthday: Birthday("01-01"))
    }

    func testPinnedComeFirstAndEachGroupKeepsTheListsOrder() {
        let roster = [character("a"), character("b"), character("c"), character("d")]
        let tidy = RosterTidy(pinned: ["d", "b"])
        XCTAssertEqual(tidy.arrange(roster, showingHidden: true).map(\.id), ["b", "d", "a", "c"])
    }

    func testHiddenRolesLeaveTheListUnlessItShowsThem() {
        let roster = [character("a"), character("b"), character("c")]
        let tidy = RosterTidy(hidden: ["b"])
        XCTAssertEqual(tidy.arrange(roster, showingHidden: false).map(\.id), ["a", "c"])
        XCTAssertEqual(tidy.arrange(roster, showingHidden: true).map(\.id), ["a", "b", "c"])
    }

    func testTheHiddenCountOnlyCountsRolesThatExist() {
        let roster = [character("a"), character("b")]
        let tidy = RosterTidy(hidden: ["b", "gone"])
        XCTAssertEqual(tidy.hiddenCount(of: roster), 1)
    }

    func testTogglingPinnedAndHiddenTogglesOnce() {
        var tidy = RosterTidy()
        tidy.togglePinned("a")
        XCTAssertTrue(tidy.isPinned("a"))
        tidy.togglePinned("a")
        XCTAssertFalse(tidy.isPinned("a"))
        tidy.toggleHidden("b")
        XCTAssertTrue(tidy.isHidden("b"))
        tidy.toggleHidden("b")
        XCTAssertFalse(tidy.isHidden("b"))
    }

    func testTheChoicesAreKeptOnTheDevice() {
        let suite = UserDefaults(suiteName: "RosterTidyTests.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        XCTAssertEqual(RosterStore.load(from: suite), RosterTidy())

        var tidy = RosterTidy()
        tidy.togglePinned("c")
        tidy.toggleHidden("a")
        RosterStore.save(tidy, to: suite)

        XCTAssertEqual(RosterStore.load(from: suite), tidy)
        XCTAssertEqual(RosterStore.load(from: suite).pinned, ["c"])
    }
}
