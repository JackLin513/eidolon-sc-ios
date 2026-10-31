import Foundation

/// One cell of the week's board: a day from Monday and a slot, and what sits in it.
public enum ScheduleCellState: Sendable, Hashable {
    case empty
    /// Saved: locked, as the producer cannot move or take it back.
    case saved(day: Int, slot: Int, job: WeeklyJob)
    /// A draft of this page, movable until the week is saved.
    case draft(day: Int, slot: Int, job: WeeklyJob)
    /// The slot is past, and nothing sits in it.
    case past
    /// The slot is under way, and nothing sits in it.
    case now
    /// Empty and to come, but the selected job cannot start here.
    case cannot

    /// The job sitting in the cell, saved or drafted.
    public var job: WeeklyJob? {
        switch self {
        case let .saved(_, _, job), let .draft(_, _, job): job
        case .empty, .past, .now, .cannot: nil
        }
    }

    /// Whether the job in the cell is a draft (not yet saved).
    public var isDraft: Bool {
        if case .draft = self { return true }
        return false
    }

    /// Whether the job in the cell is saved and locked.
    public var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

public struct ScheduleCell: Sendable, Hashable, Identifiable {
    public var day: Int
    public var slot: Int
    public var state: ScheduleCellState

    public var id: String { "\(day)-\(slot)" }

    public init(day: Int, slot: Int, state: ScheduleCellState) {
        self.day = day
        self.slot = slot
        self.state = state
    }

}

/// A job of the week and whether it is placed: saved, a draft, or still to place.
public struct ScheduleCard: Sendable, Hashable, Identifiable {
    public enum Placement: Sendable, Hashable {
        case none
        case saved(day: Int, slot: Int)
        case draft(day: Int, slot: Int)
    }

    public var job: WeeklyJob
    public var placement: Placement

    public var id: String { job.id }

    public init(job: WeeklyJob, placement: Placement) {
        self.job = job
        self.placement = placement
    }
}

/// The week's board as the page shows and changes it (spec #51): the cells with what sits
/// in them, the cards still to place, the draft being drawn, and why a save was refused.
/// Everything is decided here; the view only draws it and forwards taps.
public struct SchedulePlanner: Sendable {
    public private(set) var board: ScheduleBoard
    public let now: Date
    public let timeZone: TimeZone
    public let thisWeek: CalendarDay
    /// The drafts of this character and week, one per job.
    public private(set) var drafts: [PlacementInput]
    /// The card picked to place next, if any.
    public private(set) var selectedJobID: String?
    /// Why a draft was refused as it was saved, by job.
    public private(set) var reasons: [String: String]

    public init(
        board: ScheduleBoard,
        now: Date,
        timeZone: TimeZone,
        thisWeek: CalendarDay,
        drafts: [PlacementInput] = [],
        selectedJobID: String? = nil,
        reasons: [String: String] = [:]
    ) {
        self.board = board
        self.now = now
        self.timeZone = timeZone
        self.thisWeek = thisWeek
        self.drafts = drafts
        self.selectedJobID = selectedJobID
        self.reasons = reasons
    }

    public var cards: [ScheduleCard] {
        board.jobs.map { job in
            let placement: ScheduleCard.Placement
            if let saved = savedPlacement(for: job.id) {
                placement = .saved(day: saved.day, slot: saved.slot)
            } else if let draft = drafts.first(where: { $0.jobID == job.id }) {
                placement = .draft(day: draft.day, slot: draft.slot)
            } else {
                placement = .none
            }
            return ScheduleCard(job: job, placement: placement)
        }
    }

    /// The jobs not saved and not drafted: what is left to place.
    public var pendingCount: Int {
        cards.filter { card in
            if case .none = card.placement { return true }
            return false
        }.count
    }

    public var hasDrafts: Bool { !drafts.isEmpty }

    public func selectedJob() -> WeeklyJob? {
        guard let selectedJobID else { return nil }
        return board.jobs.first { $0.id == selectedJobID }
    }

    public func savedPlacement(for jobID: String) -> SchedulePlacement? {
        board.placements.first { $0.jobID == jobID }
    }

    /// The cell at the day from Monday and the slot.
    public func cell(day: Int, slot: Int) -> ScheduleCell {
        ScheduleCell(day: day, slot: slot, state: state(day: day, slot: slot))
    }

    public var cells: [ScheduleCell] {
        (0..<ScheduleRules.days).flatMap { day in
            (0..<3).map { slot in cell(day: day, slot: slot) }
        }
    }

    /// The saved or drafted job that takes this cell, if any, and where it starts.
    public func coveringJob(day: Int, slot: Int) -> (job: WeeklyJob, day: Int, slot: Int, draft: Bool)? {
        for placement in board.placements {
            guard let job = board.jobs.first(where: { $0.id == placement.jobID }) else { continue }
            if placement.day == day, (placement.slot..<(placement.slot + job.length)).contains(slot) {
                return (job, placement.day, placement.slot, false)
            }
        }
        for draft in drafts {
            guard let job = board.jobs.first(where: { $0.id == draft.jobID }) else { continue }
            if draft.day == day, (draft.slot..<(draft.slot + job.length)).contains(slot) {
                return (job, draft.day, draft.slot, true)
            }
        }
        return nil
    }

    public func state(day: Int, slot: Int) -> ScheduleCellState {
        if let covered = coveringJob(day: day, slot: slot) {
            if covered.draft {
                return .draft(day: covered.day, slot: covered.slot, job: covered.job)
            }
            return .saved(day: covered.day, slot: covered.slot, job: covered.job)
        }
        switch ScheduleRules.timeOf(
            local: now, timeZone: timeZone, thisWeek: thisWeek,
            week: board.week, day: day, slot: slot
        ) {
        case .past: return .past
        case .now: return .now
        case .future: break
        }
        if let job = selectedJob(), !canPlace(job, day: day, slot: slot) { return .cannot }
        return .empty
    }

    /// Whether the job can start at the cell: to come, long enough, in its slots, and not
    /// over another saved or drafted job.
    public func canPlace(_ job: WeeklyJob, day: Int, slot: Int) -> Bool {
        guard (0..<ScheduleRules.days).contains(day), (0..<3).contains(slot) else { return false }
        guard savedPlacement(for: job.id) == nil,
              !drafts.contains(where: { $0.jobID == job.id })
        else { return false }
        guard slot + job.length <= 3 else { return false }
        for at in slot..<(slot + job.length) {
            guard ScheduleRules.timeOf(
                local: now, timeZone: timeZone, thisWeek: thisWeek,
                week: board.week, day: day, slot: at
            ) == .future else { return false }
            if let slots = job.slots, !slots.contains(ScheduleSlot(rawValue: at) ?? .morning) {
                return false
            }
            if coveringJob(day: day, slot: at) != nil { return false }
        }
        return true
    }

    /// The cells the selected job can start at, in day and slot order.
    public func availableCells() -> [(day: Int, slot: Int)] {
        guard let job = selectedJob() else { return [] }
        return cells.compactMap { cell in
            canPlace(job, day: cell.day, slot: cell.slot) ? (cell.day, cell.slot) : nil
        }
    }

    /// Picks a card to place; picking it again puts it down.
    public mutating func select(_ jobID: String?) {
        if selectedJobID == jobID {
            selectedJobID = nil
        } else {
            selectedJobID = jobID
        }
    }

    /// A tap on a cell: a draft there comes back to the cards; otherwise the selected card
    /// is placed if it can start there.
    @discardableResult
    public mutating func tap(day: Int, slot: Int) -> Bool {
        if let covered = coveringJob(day: day, slot: slot) {
            if covered.draft {
                removeDraft(jobID: covered.job.id)
                return true
            }
            return false
        }
        guard let job = selectedJob(), canPlace(job, day: day, slot: slot) else { return false }
        drafts.append(PlacementInput(jobID: job.id, day: day, slot: slot))
        reasons[job.id] = nil
        selectedJobID = nil
        return true
    }

    public mutating func removeDraft(jobID: String) {
        drafts.removeAll { $0.jobID == jobID }
        reasons[jobID] = nil
    }

    /// Folds a save's answer back in: what was saved leaves the drafts, what was refused
    /// stays with why.
    public mutating func apply(_ save: ScheduleSave) {
        let saved = Set(save.saved)
        drafts.removeAll { saved.contains($0) }
        for input in save.saved { reasons[input.jobID] = nil }
        for refused in save.refused { reasons[refused.input.jobID] = refused.reason }
        if let selectedJobID, drafts.contains(where: { $0.jobID == selectedJobID }) {
            self.selectedJobID = nil
        }
    }
}

/// One of her jobs as the calendar shows it: saved, or a draft of the week's page.
public struct ScheduleCalendarEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var day: CalendarDay
    public var slot: Int
    public var length: Int
    public var characterID: String
    public var characterName: String
    public var jobName: String
    public var draft: Bool

    public init(
        id: String, day: CalendarDay, slot: Int, length: Int, characterID: String,
        characterName: String, jobName: String, draft: Bool
    ) {
        self.id = id
        self.day = day
        self.slot = slot
        self.length = length
        self.characterID = characterID
        self.characterName = characterName
        self.jobName = jobName
        self.draft = draft
    }

    public var slotsName: String {
        ScheduleRules.slotsName(slot: slot, length: length)
    }
}

public enum ScheduleCalendar {
    /// One of her jobs as a calendar entry, on the day it starts.
    public static func entry(
        character: CharacterConfig, job: WeeklyJob, day: CalendarDay, slot: Int, draft: Bool
    ) -> ScheduleCalendarEntry {
        ScheduleCalendarEntry(
            id: draft ? "draft:\(job.id)" : "schedule:\(job.id)",
            day: day,
            slot: slot,
            length: job.length,
            characterID: character.id,
            characterName: character.nameZh ?? character.name,
            jobName: job.name,
            draft: draft
        )
    }

    /// The saved and drafted jobs of `board` as calendar entries: one per job, on the day it
    /// starts.
    public static func entries(
        character: CharacterConfig, board: ScheduleBoard, drafts: [PlacementInput]
    ) -> [ScheduleCalendarEntry] {
        let jobs = Dictionary(uniqueKeysWithValues: board.jobs.map { ($0.id, $0) })
        var entries: [ScheduleCalendarEntry] = board.placements.compactMap { placement in
            guard let job = jobs[placement.jobID] else { return nil }
            return entry(
                character: character, job: job,
                day: board.week.adding(days: placement.day), slot: placement.slot, draft: false
            )
        }
        for draft in drafts {
            guard let job = jobs[draft.jobID],
                  !board.placements.contains(where: { $0.jobID == draft.jobID })
            else { continue }
            entries.append(entry(
                character: character, job: job,
                day: board.week.adding(days: draft.day), slot: draft.slot, draft: true
            ))
        }
        return entries.sorted { ($0.day, $0.slot) < ($1.day, $1.slot) }
    }
}

/// The drafts and save refusals of the schedule page, kept apart by character and week and
/// shared with the calendar so both pages see the same unsaved work.
public struct ScheduleDraftBook: Sendable, Hashable {
    public var drafts: [ScheduleDraftKey: [PlacementInput]]
    public var reasons: [ScheduleDraftKey: [String: String]]

    public init(
        drafts: [ScheduleDraftKey: [PlacementInput]] = [:],
        reasons: [ScheduleDraftKey: [String: String]] = [:]
    ) {
        self.drafts = drafts
        self.reasons = reasons
    }

    public func drafts(for key: ScheduleDraftKey) -> [PlacementInput] {
        drafts[key] ?? []
    }

    public func reasons(for key: ScheduleDraftKey) -> [String: String] {
        reasons[key] ?? [:]
    }

    public mutating func set(
        drafts: [PlacementInput], reasons: [String: String], for key: ScheduleDraftKey
    ) {
        self.drafts[key] = drafts.isEmpty ? nil : drafts
        self.reasons[key] = reasons.isEmpty ? nil : reasons
    }
}
