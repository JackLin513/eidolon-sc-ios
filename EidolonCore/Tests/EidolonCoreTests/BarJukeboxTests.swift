import XCTest
@testable import EidolonCore

/// The jukebox: the 12 slots of its picker, the small player and what a stored record is read
/// as (upstream `lib/barJukebox.ts`).
final class BarJukeboxTests: XCTestCase {
    private func track(_ id: Int) -> BarTrack {
        BarTrack(id: id, file: String(format: "%03d_t.ogg", id), title: "T\(id)")
    }

    /// 13 tracks there, the default playlist the first 12 backwards.
    private let audio = BarAudio(
        tracks: (1...13).map { BarTrack(id: $0, file: String(format: "%03d_t.ogg", $0), title: "T\($0)") },
        playlist: Array((1...12).reversed()),
        sfx: ["door"]
    )
    private let full: BarJukebox.Picked = (1...12).reversed().map { $0 }

    // MARK: - 默认的 12 首

    func testTheDefaultTwelveAreTheCatalogsDefaultPlaylist() {
        XCTAssertEqual(BarJukebox.defaultSlots(audio), full)
    }

    func testWhatTheCatalogDoesNotHaveIsLeftEmpty() {
        var short = audio
        short.playlist = [12, 11]

        XCTAssertEqual(BarJukebox.defaultSlots(short), [12, 11] + [Int?](repeating: nil, count: 10))
    }

    // MARK: - 选曲界面的 12 个槽

    func testATitleClickedGoesIntoTheFirstEmptySlotAndMayRepeat() {
        let slots: BarJukebox.Picked = [5, nil, 7, nil] + [Int?](repeating: 1, count: 8)

        XCTAssertEqual(BarJukebox.pickTrack(slots, 5), [5, 5, 7, nil] + [Int?](repeating: 1, count: 8))
    }

    func testFullATitleClickedChangesNothing() {
        XCTAssertEqual(BarJukebox.pickTrack(full, 13), full)
    }

    func testTwoSlotsClickedAreSwapped() {
        XCTAssertEqual(
            BarJukebox.swapSlots(full, 0, 11),
            [1] + Array(full[1..<11]) + [12]
        )
    }

    func testClearedTheOnesAfterItDoNotMoveUp() {
        XCTAssertEqual(BarJukebox.clearSlot(full, at: 1), [12, nil] + Array(full[2...]))
    }

    func testAllTwelvePickedIsReady() {
        XCTAssertTrue(BarJukebox.isReady(full))
        XCTAssertFalse(BarJukebox.isReady(BarJukebox.clearSlot(full, at: 5)))
    }

    // MARK: - 存在这台设备上

    func testNothingKeptIsTheDefaultTwelvePlayingInOrder() {
        XCTAssertEqual(
            BarJukebox.read(nil, audio),
            BarJukebox.State(slots: full, isPaused: false, mode: .order)
        )
    }

    func testWhatWasKeptIsReadBack() {
        let mine = BarJukebox.State(slots: [13] + Array(full[1...]), isPaused: true, mode: .shuffle)

        XCTAssertEqual(BarJukebox.read(mine, audio), mine)
    }

    func testAPickThatCannotBeReadIsTheDefault() {
        for slots in [[99] + Array(full[1...]), Array(full[1...]), [nil] + Array(full[1...])] {
            XCTAssertEqual(
                BarJukebox.read(.init(slots: slots, isPaused: true, mode: .loop), audio),
                .init(slots: full, isPaused: true, mode: .loop),
                "\(slots)"
            )
        }
    }

    // MARK: - 小播放器

    func testInOrderTheNextSlotAndTheTwelfthBackToTheFirst() {
        XCTAssertEqual(BarJukebox.slotAfter(.order, 0, random: { 0 }), 1)
        XCTAssertEqual(BarJukebox.slotAfter(.order, 11, random: { 0 }), 0)
    }

    func testLoopingThisOneAgainButNextStillGoesOn() {
        XCTAssertEqual(BarJukebox.slotAfter(.loop, 4, random: { 0 }), 4)
        XCTAssertEqual(BarJukebox.nextSlot(.loop, 4, random: { 0 }), 5)
    }

    func testShuffledAnyOtherSlotNeverThisOne() {
        XCTAssertEqual(BarJukebox.slotAfter(.shuffle, 3, random: { 0.2 }), 2)
        XCTAssertEqual(BarJukebox.nextSlot(.shuffle, 3, random: { 0.3 }), 4)
    }

    func testPreviousGoesBackAndTheFirstBackToTheTwelfth() {
        XCTAssertEqual(BarJukebox.previousSlot(5), 4)
        XCTAssertEqual(BarJukebox.previousSlot(0), 11)
    }

    func testShuffleAndLoopAreExclusive() {
        XCTAssertEqual(BarJukebox.toggleMode(.loop, .shuffle), .shuffle)
        XCTAssertEqual(BarJukebox.toggleMode(.shuffle, .shuffle), .order)
    }

    // MARK: - 左边一页几首

    func testFiveATitleAPageAndTheLastPageAsManyAsAreLeft() {
        XCTAssertEqual(BarJukebox.pages(audio.tracks), 3)
        XCTAssertEqual(BarJukebox.page(audio.tracks, 0).map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(BarJukebox.page(audio.tracks, 2).map(\.id), [11, 12, 13])
    }
}

/// Which tracks and sound effects the bar can play: the catalog, and what its sound package has
/// (upstream `lib/barAudio.ts`).
final class BarAudioTests: XCTestCase {
    private let catalog = BarAudioCatalog(
        tracks: [
            BarTrack(id: 22, file: "022_a.ogg", title: "A"),
            BarTrack(id: 5, file: "005_b.ogg", title: "B"),
            BarTrack(id: 9, file: "009_c.ogg", title: "C"),
        ],
        defaultPlaylist: [9, 22, 5],
        sfx: [BarSoundEffect(name: "door", file: "095_door.ogg"),
              BarSoundEffect(name: "bleep_high", file: "083_bleep_high.ogg")]
    )

    func testOnlyWhatBothTheCatalogAndThePackageHaveInTheCatalogsOrder() {
        let audio = catalog.available(with: BarAudioPackage(tracks: [5, 9, 77], sfx: ["door", "unknown"]))

        XCTAssertEqual(audio.tracks.map(\.id), [5, 9])
        XCTAssertEqual(audio.playlist, [9, 5])
        XCTAssertEqual(audio.sfx, ["door"])
    }

    func testWithoutAPackageThereIsNothing() {
        XCTAssertEqual(catalog.available(with: nil), BarAudio())
        XCTAssertFalse(catalog.available(with: nil).hasJukebox)
    }

    func testOneTrackIsAJukebox() {
        XCTAssertTrue(catalog.available(with: BarAudioPackage(tracks: [22], sfx: [])).hasJukebox)
    }
}
