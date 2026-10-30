import Foundation

/// The jukebox (`.scratch/bar-room` spec「点唱机」; upstream `lib/barJukebox.ts`): the 12 slots of
/// its picker, the small player's previous / next / shuffle / loop, and how they are kept on the
/// device. Tracks are the original's sound numbers, one a slot, repeats allowed.
///
/// How the picker's slots are chosen is here, as rules; keeping them on the device is the app's.
public enum BarJukebox {
    /// The picker's slots: that many picked, Ready!.
    public static let slots = 12
    /// How many titles a page of the picker's list holds.
    public static let pageSize = 5

    /// How the small player goes on, and whether it is in play.
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        case order, shuffle, loop
    }

    /// The 12 slots, a track's number in each, an empty one `nil`.
    public typealias Picked = [Int?]

    /// What the device keeps: the 12 picked and how the player plays.
    public struct State: Codable, Sendable, Hashable {
        public var slots: Picked
        public var isPaused: Bool
        public var mode: Mode

        public init(slots: Picked, isPaused: Bool = false, mode: Mode = .order) {
            self.slots = slots
            self.isPaused = isPaused
            self.mode = mode
        }
    }

    /// The default 12: the catalog's default playlist (only what there is), the rest empty.
    public static func defaultSlots(_ audio: BarAudio) -> Picked {
        (0..<slots).map { $0 < audio.playlist.count ? audio.playlist[$0] : nil }
    }

    /// A title clicked: into the first empty slot; full, nothing changes.
    public static func pickTrack(_ picked: Picked, _ id: Int) -> Picked {
        guard let at = picked.firstIndex(where: { $0 == nil }) else { return picked }
        var picked = picked
        picked[at] = id
        return picked
    }

    /// Two slots clicked: swapped.
    public static func swapSlots(_ picked: Picked, _ a: Int, _ b: Int) -> Picked {
        var picked = picked
        picked.swapAt(a, b)
        return picked
    }

    /// One slot cleared, the ones after it not moved up.
    public static func clearSlot(_ picked: Picked, at: Int) -> Picked {
        var picked = picked
        picked[at] = nil
        return picked
    }

    /// All 12 picked: Ready!.
    public static func isReady(_ picked: Picked) -> Bool {
        picked.count == slots && picked.allSatisfy { $0 != nil }
    }

    /// How many pages the titles on the left have: as many as the tracks, five a page.
    public static func pages(_ tracks: [BarTrack]) -> Int {
        (tracks.count + pageSize - 1) / pageSize
    }

    /// The titles of page `page` (from 0).
    public static func page(_ tracks: [BarTrack], _ page: Int) -> [BarTrack] {
        let start = page * pageSize
        guard start < tracks.count else { return [] }
        return Array(tracks[start..<min(start + pageSize, tracks.count)])
    }

    /// Which slot (from 0) plays after `at` is done: looping, this one again; shuffled, any other;
    /// in order, the next, the 12th going back to the first.
    public static func slotAfter(
        _ mode: Mode, _ at: Int, random: () -> Double = { .random(in: 0..<1) }
    ) -> Int {
        mode == .loop ? at : nextSlot(mode, at, random: random)
    }

    /// The small player's next: shuffled, any other slot; else the next (looping too).
    public static func nextSlot(
        _ mode: Mode, _ at: Int, random: () -> Double = { .random(in: 0..<1) }
    ) -> Int {
        guard mode == .shuffle else { return (at + 1) % slots }
        let pick = Int((random() * Double(slots - 1)).rounded(.down))
        return pick >= at ? pick + 1 : pick
    }

    /// The small player's previous: the one before, the first going back to the 12th.
    public static func previousSlot(_ at: Int) -> Int {
        (at - 1 + slots) % slots
    }

    /// Shuffle or loop clicked: on is off, off is on and the other goes off with it.
    public static func toggleMode(_ mode: Mode, _ which: Mode) -> Mode {
        mode == which ? .order : which
    }

    /// What the device's record says, each part read as it should be: a picker not 12 tracks
    /// there are is the default; a pause not true or false is playing; a mode not one of the
    /// three is in order. What upstream's `storedJukebox` does with what it reads.
    public static func read(_ kept: State?, _ audio: BarAudio) -> State {
        let ids = Set(audio.tracks.map(\.id))
        let mine = kept.flatMap { state in
            state.slots.count == slots && state.slots.allSatisfy { $0.map(ids.contains) ?? false }
                ? state.slots : nil
        }
        return State(
            slots: mine ?? defaultSlots(audio),
            isPaused: kept?.isPaused ?? false,
            mode: kept?.mode ?? .order
        )
    }
}
