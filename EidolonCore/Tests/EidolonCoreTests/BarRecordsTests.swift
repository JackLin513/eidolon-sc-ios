import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// The bar's records in the user library (GLOSSARY.md「光顾」; ADR-0021): one row per visit
/// done, what is read of it before she comes in, and the day it is of.
final class BarRecordsTests: BarTestCase {
    private let enter = Date(timeIntervalSince1970: 1_790_000_000)
    private let leave = Date(timeIntervalSince1970: 1_790_000_000 + 1_800)

    private func serving(_ id: String, _ tier: Tier, positivity: Bool = true) throws -> Serving {
        let catalog = content.content.catalog
        let drink = try XCTUnwrap(catalog.drink(id: id))
        let order = BarOrder(target: drink)
        return Serving(
            order: order, served: Served(drink: drink, big: false, karmotrine: 0), tier: tier
        )
    }

    // MARK: - The schema

    func testTheLibraryHasTheBarVisitsTableAfterTheUpgrade() throws {
        let columns: [String] = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('bar_visits')")
        }
        XCTAssertEqual(
            columns,
            [
                "id", "character_id", "entered_at", "left_at", "entered_on", "reason", "topic",
                "orders", "drunk", "rewarded",
            ]
        )
    }

    func testAVisitDoneIsWrittenDownAsItWasServed() throws {
        let servings = [try serving("adelhyde-flavor", .best), try serving("bronson-aged", .wrong)]

        let id: Int64 = try queue.write { db in
            try BarRecords.insert(
                db, characterID: "mano", enteredAt: enter, leftAt: leave,
                enteredOn: "2026-09-21", reason: "reason-1", topic: "topic-2", servings: servings,
                drunk: true, rewarded: true
            )
        }

        let record = try XCTUnwrap(try queue.read { db in try BarRecords.all(db) }.first)
        XCTAssertEqual(id, record.id)
        XCTAssertEqual(record.characterID, "mano")
        XCTAssertEqual(record.enteredOn, "2026-09-21")
        XCTAssertEqual(record.reason, "reason-1")
        XCTAssertEqual(record.topic, "topic-2")
        XCTAssertEqual(record.orders.count, 2)
        XCTAssertEqual(record.orders[0].served, "adelhyde-flavor")
        XCTAssertEqual(record.orders[0].tier, .best)
        XCTAssertEqual(record.orders[1].tier, .wrong)
        XCTAssertTrue(record.drunk)
        XCTAssertTrue(record.rewarded)
        // The stamps are the library's, to the microsecond.
        XCTAssertEqual(record.enteredAt.timeIntervalSince1970, enter.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(record.leftAt.timeIntervalSince1970, leave.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - What is read before she comes in

    func testAVisitDoneOnADayCountsForThatDayOnly() throws {
        try queue.write { db in
            try BarRecords.insert(
                db, characterID: "mano", enteredAt: enter, leftAt: leave, enteredOn: "2026-09-21",
                reason: "reason-1", topic: "topic-1", servings: [], drunk: false, rewarded: true
            )
        }

        let (sameDay, otherDay, before) = try queue.read { db in
            (
                try BarRecords.doneOn(db, day: "2026-09-21"),
                try BarRecords.doneOn(db, day: "2026-09-22"),
                try BarRecords.before(db, today: "2026-09-22")
            )
        }

        XCTAssertTrue(sameDay)
        XCTAssertFalse(otherDay)
        XCTAssertEqual(before, BarBefore(doneToday: false, visitsDone: 1))
    }

    func testSheRemembersOnlyHerLatestThreeVisitsReasonsAndTopics() throws {
        try queue.write { db in
            for n in 1...4 {
                try BarRecords.insert(
                    db, characterID: "mano", enteredAt: enter.addingTimeInterval(Double(n)),
                    leftAt: leave.addingTimeInterval(Double(n)), enteredOn: "2026-09-2\(n)",
                    reason: "reason-\(n)", topic: "topic-\(n)", servings: [], drunk: n == 2,
                    rewarded: false
                )
            }
            // Another character's visits are not hers to remember.
            try BarRecords.insert(
                db, characterID: "hiori", enteredAt: enter, leftAt: leave, enteredOn: "2026-09-21",
                reason: "reason-9", topic: "topic-9", servings: [], drunk: false, rewarded: false
            )
        }

        let history = try queue.read { db in try BarRecords.history(db, characterID: "mano") }

        XCTAssertEqual(history.remembered.visits, 4)
        XCTAssertEqual(history.reasons, ["reason-4", "reason-3", "reason-2"])
        XCTAssertEqual(history.topics, ["topic-4", "topic-3", "topic-2"])
        XCTAssertFalse(history.remembered.lastDrunk)
        XCTAssertEqual(history.remembered.lastLeftAt, leave.addingTimeInterval(4))
    }

    func testAFirstVisitRemembersNothingButThatThereWereNone() throws {
        let history = try queue.read { db in try BarRecords.history(db, characterID: "mano") }

        XCTAssertEqual(history.remembered, BarPrompt.Remembered())
        XCTAssertTrue(history.reasons.isEmpty)
        XCTAssertTrue(history.topics.isEmpty)
    }

    func testWhatSheRemembersHerLastVisitByIsWhatSheWanted() throws {
        // Served wrong, the drink is not what she wanted: the one she ordered is.
        let order = BarOrder(target: try XCTUnwrap(content.content.catalog.drink(id: "adelhyde-flavor")))
        let served = try XCTUnwrap(content.content.catalog.drink(id: "bronson-aged"))
        let wrong = Serving(
            order: order, served: Served(drink: served, big: true, karmotrine: 2), tier: .wrong
        )
        let right = Serving(
            order: order,
            served: Served(drink: order.target, big: false, karmotrine: 0), tier: .best
        )
        try queue.write { db in
            try BarRecords.insert(
                db, characterID: "mano", enteredAt: enter, leftAt: leave, enteredOn: "2026-09-21",
                reason: "reason-1", topic: "topic-1", servings: [wrong, right], drunk: false,
                rewarded: true
            )
        }

        let history = try queue.read { db in try BarRecords.history(db, characterID: "mano") }

        XCTAssertEqual(history.remembered.lastOrders.map(\.wanted), ["adelhyde-flavor", "adelhyde-flavor"])
        XCTAssertEqual(history.remembered.lastOrders.map(\.served), ["bronson-aged", "adelhyde-flavor"])
        XCTAssertTrue(history.remembered.lastOrders[0].big)
    }

    // MARK: - The day

    /// The bar's day is the device's (ADR-0021), not the server's: the same instant is a
    /// different day east and west of it.
    func testTheDayIsTheDevices() {
        // 2026-10-28 17:30 UTC is 01:30 the next day in Tokyo, still the 28th in Los Angeles.
        let moment = Date(timeIntervalSince1970: 1_793_208_600)

        XCTAssertEqual(BarDates.day(of: moment, in: TimeZone(identifier: "Asia/Tokyo")!), "2026-10-29")
        XCTAssertEqual(
            BarDates.day(of: moment, in: TimeZone(identifier: "America/Los_Angeles")!), "2026-10-28"
        )
    }
}
