import Foundation
import XCTest
@testable import EidolonCore

/// The outfit thumbnails' cache and the wait for a slow one (spec「通话页」).
final class OutfitThumbnailTests: XCTestCase {
    /// A thumbnail belongs to the outfit *and* the content bundle it was drawn from: a new
    /// bundle shows new art instead of the old picture at the same outfit number.
    func testAThumbnailIsCachedUnderTheOutfitAndTheContentVersion() {
        XCTAssertEqual(
            OutfitThumbnailKey.fileName(
                outfitID: "stand/1030010010",
                contentVersion: "2026-10-27T09:31:00Z"
            ),
            "stand_1030010010-2026-10-27T09_31_00Z.png"
        )
        XCTAssertNotEqual(
            OutfitThumbnailKey.fileName(outfitID: "stand/1030010010", contentVersion: "a"),
            OutfitThumbnailKey.fileName(outfitID: "stand/1030010010", contentVersion: "b")
        )
    }

    /// A card that scrolls away cancels its wait, so the next one is not stuck behind a slow
    /// load for the whole timeout.
    func testACancelledWaitEndsWithoutWaitingForTheTimeout() async {
        let waiter = LoadWaiter()
        let start = ContinuousClock.now
        let waiting = Task { await waiter.wait(timeout: .seconds(10)) }
        try? await Task.sleep(for: .milliseconds(50))
        waiting.cancel()

        let loaded = await waiting.value
        XCTAssertFalse(loaded)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        // A late load report after the cancellation is harmless.
        waiter.finish(true)
    }

    func testAWaitEndsWhenTheLoadReports() async {
        let waiter = LoadWaiter()
        let waiting = Task { await waiter.wait(timeout: .seconds(10)) }
        waiter.finish(true)
        let loaded = await waiting.value
        XCTAssertTrue(loaded)
    }

    func testAWaitEndsAsFailedAtTheTimeout() async {
        let waiter = LoadWaiter()
        let start = ContinuousClock.now
        let loaded = await waiter.wait(timeout: .milliseconds(100))
        XCTAssertFalse(loaded)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(90))
    }
}
