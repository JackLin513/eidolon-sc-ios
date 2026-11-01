import Foundation
import GRDB

/// A slot of her day (upstream `job_list.Slot`): 上午 6–12, 下午 12–18, 晚上 18–24.
public enum ScheduleSlot: Int, CaseIterable, Sendable, Hashable {
    case morning = 0
    case afternoon = 1
    case evening = 2

    public var name: String {
        switch self {
        case .morning: "上午"
        case .afternoon: "下午"
        case .evening: "晚上"
        }
    }

    /// The job list writes the slots by name (`morning`, `afternoon`, `evening`).
    var listedName: String {
        switch self {
        case .morning: "morning"
        case .afternoon: "afternoon"
        case .evening: "evening"
        }
    }
}

extension ScheduleSlot: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self), let slot = Self(rawValue: number) {
            self = slot
            return
        }
        let name = try container.decode(String.self)
        guard let slot = Self.allCases.first(where: { $0.listedName == name }) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "没有这个时间段：\(name)"
            )
        }
        self = slot
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(listedName)
    }
}

/// One job in the content bundle's `characters/jobs.json` (upstream `job_list.ListedJob`).
public struct ListedJob: Codable, Sendable, Hashable, Identifiable {
    public enum Category: String, Codable, Sendable, Hashable {
        case practice
        case appearance
        case business
        case `private`

        public var isWork: Bool { self != .private }
    }

    public var id: String
    public var name: String
    public var note: String
    public var category: Category
    public var length: Int
    public var slots: [ScheduleSlot]?

    public init(
        id: String, name: String, note: String, category: Category, length: Int,
        slots: [ScheduleSlot]? = nil
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.category = category
        self.length = length
        self.slots = slots
    }
}

/// A job of one week, as it was drawn: the snapshot the schedule keeps (upstream `Job`).
public struct WeeklyJob: Sendable, Hashable, Identifiable {
    public var id: String
    public var week: CalendarDay
    public var characterID: String
    public var listedID: String
    public var name: String
    public var note: String
    public var category: ListedJob.Category
    public var length: Int
    public var slots: [ScheduleSlot]?

    public init(
        id: String, week: CalendarDay, characterID: String, listedID: String,
        name: String, note: String, category: ListedJob.Category, length: Int,
        slots: [ScheduleSlot]?
    ) {
        self.id = id
        self.week = week
        self.characterID = characterID
        self.listedID = listedID
        self.name = name
        self.note = note
        self.category = category
        self.length = length
        self.slots = slots
    }
}

public struct SchedulePlacement: Sendable, Hashable {
    public var week: CalendarDay
    public var jobID: String
    public var characterID: String
    public var day: Int
    public var slot: Int
    public var savedAt: String
    public var countedAt: String?

    public init(
        week: CalendarDay, jobID: String, characterID: String, day: Int, slot: Int,
        savedAt: String, countedAt: String? = nil
    ) {
        self.week = week
        self.jobID = jobID
        self.characterID = characterID
        self.day = day
        self.slot = slot
        self.savedAt = savedAt
        self.countedAt = countedAt
    }
}

public struct PlacementInput: Sendable, Hashable {
    public var jobID: String
    public var day: Int
    public var slot: Int

    public init(jobID: String, day: Int, slot: Int) {
        self.jobID = jobID
        self.day = day
        self.slot = slot
    }
}

public struct RefusedPlacement: Sendable, Hashable {
    public var input: PlacementInput
    public var reason: String

    public init(input: PlacementInput, reason: String) {
        self.input = input
        self.reason = reason
    }
}

public struct ScheduleSave: Sendable, Hashable {
    public var saved: [PlacementInput]
    public var refused: [RefusedPlacement]

    public init(saved: [PlacementInput] = [], refused: [RefusedPlacement] = []) {
        self.saved = saved
        self.refused = refused
    }
}

/// One saved placement with the job it places, across every week and character (spec #56).
public struct SavedPlacement: Sendable, Hashable, Identifiable {
    public var job: WeeklyJob
    public var placement: SchedulePlacement

    public var id: String { job.id }

    public init(job: WeeklyJob, placement: SchedulePlacement) {
        self.job = job
        self.placement = placement
    }
}

/// One of her saved jobs, with the week and slot it sits in (upstream `HerJob`).
public struct HerJob: Sendable, Hashable {
    public var job: WeeklyJob
    public var week: CalendarDay
    public var day: Int
    public var slot: Int

    public init(job: WeeklyJob, week: CalendarDay, day: Int, slot: Int) {
        self.job = job
        self.week = week
        self.day = day
        self.slot = slot
    }
}

/// Her jobs the producer saved for the week and the next, it being `local` where they are
/// (upstream `HerSchedule`).
public struct HerSchedule: Sendable {
    public var local: Date
    public var timeZone: TimeZone
    public var thisWeek: CalendarDay
    public var jobs: [HerJob]

    public init(local: Date, timeZone: TimeZone, thisWeek: CalendarDay, jobs: [HerJob]) {
        self.local = local
        self.timeZone = timeZone
        self.thisWeek = thisWeek
        self.jobs = jobs
    }

    public var localDay: CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: local)
        return CalendarDay(
            year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0
        )
    }

    public func timeOf(week: CalendarDay, day: Int, slot: Int) -> ScheduleTime {
        ScheduleRules.timeOf(
            local: local, timeZone: timeZone, thisWeek: thisWeek,
            week: week, day: day, slot: slot
        )
    }

    public func done(_ her: HerJob) -> Bool {
        ScheduleRules.isDone(
            local: local, timeZone: timeZone, thisWeek: thisWeek,
            week: her.week, day: her.day, slot: her.slot, length: her.job.length
        )
    }

    /// Her job the producer scheduled today and she has done, the latest if more than one.
    public func doneToday() -> WeeklyJob? {
        let today = localDay.weekdayIndex
        return jobs.last {
            $0.week == thisWeek && $0.day == today && done($0)
        }?.job
    }
}

public enum ScheduleTime: Sendable, Hashable {
    case past
    case now
    case future
}

/// One week of one character, as the schedule board shows it.
public struct ScheduleBoard: Sendable, Hashable {
    public var week: CalendarDay
    public var isCurrent: Bool
    public var jobs: [WeeklyJob]
    public var placements: [SchedulePlacement]

    public init(
        week: CalendarDay, isCurrent: Bool, jobs: [WeeklyJob],
        placements: [SchedulePlacement]
    ) {
        self.week = week
        self.isCurrent = isCurrent
        self.jobs = jobs
        self.placements = placements
    }
}

public enum ScheduleRules {
    /// The Monday the rounds are counted from (upstream `FIRST_WEEK`).
    public static let firstWeek = CalendarDay(year: 2026, month: 1, day: 5)
    public static let rotation = 4
    public static let jobsEach = 2...3
    public static let totalLength = 24...27
    public static let drawTries = 100
    public static let slotHours = 6
    public static let days = 7
    public static let jobDoneStep = 0.5

    /// The week being published: the Monday Beijing is in (upstream `week_of`).
    public static func week(of now: Date) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let day = CalendarDay(
            year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0
        )
        return day.adding(days: -day.weekdayIndex)
    }

    /// 0–6 for the producer's local day, from Monday.
    public static func localWeekday(now: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return CalendarDay(
            year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0
        ).weekdayIndex
    }

    public static func timeOf(
        local: Date, timeZone: TimeZone, thisWeek: CalendarDay,
        week: CalendarDay, day: Int, slot: Int
    ) -> ScheduleTime {
        if week != thisWeek {
            return week < thisWeek ? .past : .future
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: local)
        let today = localWeekday(now: local, timeZone: timeZone)
        if day != today { return day < today ? .past : .future }
        if hour < slotHours { return .future }
        let current = hour / slotHours - 1
        if slot < current { return .past }
        if slot == current { return .now }
        return .future
    }

    /// The slots a job takes, from `slot`: 上午, 上午到下午, 一整天.
    public static func slotsName(slot: Int, length: Int) -> String {
        if length == 3 { return "一整天" }
        let names = ScheduleSlot.allCases.map(\.name)
        let first = names[slot]
        return length == 1 ? first : "\(first)到\(names[slot + length - 1])"
    }

    public static func isDone(
        local: Date, timeZone: TimeZone, thisWeek: CalendarDay,
        week: CalendarDay, day: Int, slot: Int, length: Int
    ) -> Bool {
        if week != thisWeek { return week < thisWeek }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: local)
        let today = localWeekday(now: local, timeZone: timeZone)
        if day != today { return day < today }
        if hour < slotHours { return false }
        let current = hour / slotHours - 1
        return slot + length - 1 < current
    }

    /// The week's idols and the jobs each is given (upstream `draw_week`). The random
    /// sequence is this app's own, seeded by the round and the week; it needs no server's.
    public static func drawWeek(
        week: CalendarDay, idols: [String], jobs: [ListedJob]
    ) throws -> [(characterID: String, job: ListedJob)] {
        guard !idols.isEmpty, !jobs.isEmpty else { return [] }
        let weeks = week.days(since: firstWeek)
        guard weeks >= 0 else { return [] }
        let round = weeks / 7 / rotation
        let group = (weeks / 7) % rotation
        var shuffled = idols
        var roundRandom = SeededRandom(seed: "round \(round)")
        roundRandom.shuffle(&shuffled)
        let size = shuffled.count / rotation
        let more = shuffled.count % rotation
        let start = group * size + min(group, more)
        let count = size + (group < more ? 1 : 0)
        let ofTheWeek = Array(shuffled[start..<(start + count)])
        var drawing = SeededRandom(seed: "week \(week.stamp)")
        for _ in 0..<drawTries {
            if let drawn = drawOnce(&drawing, idols: ofTheWeek, jobs: jobs) {
                let total = drawn.reduce(0) { $0 + $1.job.length }
                if totalLength.contains(total) { return drawn }
            }
        }
        throw EidolonError.invalidContent("工作清单抽不出这一周的工作")
    }

    private static func drawOnce(
        _ random: inout SeededRandom, idols: [String], jobs: [ListedJob]
    ) -> [(characterID: String, job: ListedJob)]? {
        var left = jobs
        random.shuffle(&left)
        var drawn: [(characterID: String, job: ListedJob)] = []
        for idol in idols {
            guard let work = left.first(where: { $0.category.isWork }) else { return nil }
            left.removeAll { $0.id == work.id }
            var given = [work]
            let count = jobsEach.lowerBound
                + random.below(jobsEach.upperBound - jobsEach.lowerBound + 1)
            for _ in 1..<count {
                let hasPrivate = given.contains { $0.category == .private }
                guard let more = left.first(where: { !(hasPrivate && $0.category == .private) })
                else { return nil }
                left.removeAll { $0.id == more.id }
                given.append(more)
            }
            drawn.append(contentsOf: given.map { (idol, $0) })
        }
        return drawn
    }
}

/// A small deterministic generator (SplitMix64), seeded by a stable string hash: the same
/// week and round draw the same jobs on this device for ever.
struct SeededRandom {
    private var state: UInt64

    init(seed: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        state = hash == 0 ? 0x9e37_79b9_7f4a_7c15 : hash
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    mutating func below(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(next() % UInt64(count))
    }

    mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        for i in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(i, below(i + 1))
        }
    }
}

// MARK: - Reading the job list and the weeks

extension Eidolon {
    /// Who has jobs: the characters in idol order, but the office's staff (upstream
    /// `idols_of`).
    func idolIDs() throws -> [String] {
        let world = try loadWorld()
        return TodayPrompt.idolOrder(try characters())
            .filter { world?.isStaff($0.name) != true }
            .map(\.id)
    }

    /// The content bundle's work list (`characters/jobs.json`); empty when the bundle
    /// predates it.
    public func jobList() throws -> [ListedJob] {
        let url = location.contentDirectory
            .appendingPathComponent("characters/jobs.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        struct Document: Decodable { var jobs: [ListedJob] }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        } catch {
            throw EidolonError.invalidContent("工作清单读不出来：\(error.localizedDescription)")
        }
        try Self.validateJobs(document.jobs)
        return document.jobs
    }

    static func validateJobs(_ jobs: [ListedJob]) throws {
        var seen: Set<String> = []
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        for job in jobs {
            guard !job.id.isEmpty, job.id.unicodeScalars.allSatisfy(allowed.contains) else {
                throw EidolonError.invalidContent("工作清单里的标识不合法：\(job.id)")
            }
            guard seen.insert(job.id).inserted else {
                throw EidolonError.invalidContent("工作清单里的标识重复：\(job.id)")
            }
            guard !job.name.isEmpty, !job.note.isEmpty else {
                throw EidolonError.invalidContent("工作 \(job.id) 缺少名字或说明")
            }
            guard (1...3).contains(job.length) else {
                throw EidolonError.invalidContent("工作 \(job.id) 的长度应为 1–3")
            }
            if job.length == 3, let slots = job.slots, !slots.contains(.morning) {
                throw EidolonError.invalidContent("工作 \(job.id) 是一整天的，只能从上午开始")
            }
        }
    }

    /// The week's jobs, drawn and kept the first time the week is read.
    public func scheduleWeek(_ week: CalendarDay) throws -> [WeeklyJob] {
        let idols = try idolIDs()
        let jobs = try jobList()
        return try userQueue.write { db in
            try Self.ensureWeekDrawn(db, week: week, idols: idols, jobs: jobs)
            return try Self.weeklyJobs(db, week: week, characterID: nil)
        }
    }

    /// One character's week, with the jobs drawn for her and the placements saved.
    public func scheduleBoard(
        characterID: String, week: CalendarDay, now: Date = Date(), timeZone: TimeZone
    ) throws -> ScheduleBoard {
        let thisWeek = ScheduleRules.week(of: now)
        let idols = try idolIDs()
        let listed = try jobList()
        return try userQueue.write { db in
            try Self.countDoneJobs(db, now: now, timeZone: timeZone, thisWeek: thisWeek)
            try Self.ensureWeekDrawn(db, week: week, idols: idols, jobs: listed)
            let jobs = try Self.weeklyJobs(db, week: week, characterID: characterID)
            let placements = try Self.placements(db, week: week, characterID: characterID)
            return ScheduleBoard(
                week: week, isCurrent: week == thisWeek, jobs: jobs, placements: placements
            )
        }
    }

    /// Her saved jobs for this week and the next, as her prompt and the bar read them.
    public func schedule(
        characterID: String, now: Date = Date(), timeZone: TimeZone
    ) throws -> HerSchedule {
        let thisWeek = ScheduleRules.week(of: now)
        let nextWeek = thisWeek.adding(days: ScheduleRules.days)
        let idols = try idolIDs()
        let jobs = try jobList()
        return try userQueue.write { db in
            try Self.countDoneJobs(db, now: now, timeZone: timeZone, thisWeek: thisWeek)
            try Self.ensureWeekDrawn(db, week: thisWeek, idols: idols, jobs: jobs)
            try Self.ensureWeekDrawn(db, week: nextWeek, idols: idols, jobs: jobs)
            let rows = try Self.placementRows(
                db, characterID: characterID, weeks: [thisWeek, nextWeek]
            )
            let weekly = Dictionary(
                uniqueKeysWithValues: try Self.weeklyJobs(
                    db, weeks: [thisWeek, nextWeek], characterID: characterID
                ).map { ($0.id, $0) }
            )
            let hers = rows.compactMap { row -> HerJob? in
                guard let job = weekly[row.jobID] else { return nil }
                return HerJob(job: job, week: row.week, day: row.day, slot: row.slot)
            }
            return HerSchedule(
                local: now, timeZone: timeZone, thisWeek: thisWeek, jobs: hers
            )
        }
    }

    /// The job of hers the producer scheduled today and she has done, if any: the bar's
    /// reason may be it.
    public func scheduleDoneTodayJob(
        characterID: String, now: Date = Date(), timeZone: TimeZone
    ) throws -> WeeklyJob? {
        try schedule(characterID: characterID, now: now, timeZone: timeZone).doneToday()
    }

    /// The prompt lines about her schedule (upstream `schedule_lines`); none without
    /// placements.
    public func scheduleLines(
        characterID: String, now: Date = Date(), timeZone: TimeZone
    ) throws -> [String] {
        SchedulePrompt.lines(try schedule(characterID: characterID, now: now, timeZone: timeZone))
    }

    /// This and next week's saved and drafted jobs across every character, and how many of
    /// this week's jobs are still to place (spec #51). For the calendar page.
    public func scheduleOverview(
        now: Date = Date(), timeZone: TimeZone,
        drafts: [ScheduleDraftKey: [PlacementInput]] = [:]
    ) throws -> ScheduleOverview {
        let thisWeek = ScheduleRules.week(of: now)
        let nextWeek = thisWeek.adding(days: ScheduleRules.days)
        let idols = try idolIDs()
        let listed = try jobList()
        let characters = try characters()
        return try userQueue.write { db in
            try Self.ensureWeekDrawn(db, week: thisWeek, idols: idols, jobs: listed)
            try Self.ensureWeekDrawn(db, week: nextWeek, idols: idols, jobs: listed)
            let byID = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
            let jobs = try Self.weeklyJobs(db, weeks: [thisWeek, nextWeek], characterID: nil)
            let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
            let placements = try Self.allPlacementRows(db, weeks: [thisWeek, nextWeek])
            let saved = Set(placements.map(\.jobID))
            var entries: [ScheduleCalendarEntry] = []
            for placement in placements {
                guard let job = jobsByID[placement.jobID],
                      let character = byID[placement.characterID]
                else { continue }
                entries.append(ScheduleCalendar.entry(
                    character: character, job: job,
                    day: placement.week.adding(days: placement.day),
                    slot: placement.slot, draft: false
                ))
            }
            for (key, inputs) in drafts.sorted(by: {
                ($0.key.week, $0.key.characterID) < ($1.key.week, $1.key.characterID)
            }) {
                guard key.week == thisWeek || key.week == nextWeek,
                      let character = byID[key.characterID]
                else { continue }
                for input in inputs where !saved.contains(input.jobID) {
                    guard let job = jobsByID[input.jobID] else { continue }
                    entries.append(ScheduleCalendar.entry(
                        character: character, job: job,
                        day: key.week.adding(days: input.day),
                        slot: input.slot, draft: true
                    ))
                }
            }
            entries.sort { ($0.day, $0.slot) < ($1.day, $1.slot) }
            // A job counts as placed once saved or drafted this week.
            let thisJobs = jobs.filter { $0.week == thisWeek }
            var placed = Set(
                placements.filter { $0.week == thisWeek }.map(\.jobID)
            )
            for (key, inputs) in drafts where key.week == thisWeek {
                placed.formUnion(inputs.map(\.jobID))
            }
            return ScheduleOverview(
                entries: entries,
                pendingThisWeek: max(thisJobs.count - placed.intersection(thisJobs.map(\.id)).count, 0),
                hasJobList: !listed.isEmpty
            )
        }
    }

    /// Every saved placement with its job, across all weeks and characters, for the system
    /// calendar export (spec #56). Drafts are not in the database and so are not here.
    public func savedPlacements() throws -> [SavedPlacement] {
        try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.week AS placement_week, p.job_id AS placement_job_id,
                           p.day, p.slot, p.saved_at, p.counted_at,
                           j.id AS job_id, j.week AS job_week,
                           j.character_id, j.listed_id, j.name, j.note, j.category,
                           j.length, j.slots
                    FROM schedule_placements p
                    JOIN weekly_jobs j ON j.id = p.job_id
                    ORDER BY p.week, p.day, p.slot, p.character_id, j.rowid
                    """
            ).map { row in
                let placementWeek = Self.calendarDay(row["placement_week"])
                let jobWeek = Self.calendarDay(row["job_week"])
                let slots = (row["slots"] as String?)?.split(separator: ",").compactMap {
                    Int($0).flatMap(ScheduleSlot.init(rawValue:))
                }
                let job = WeeklyJob(
                    id: row["job_id"],
                    week: jobWeek,
                    characterID: row["character_id"],
                    listedID: row["listed_id"],
                    name: row["name"],
                    note: row["note"],
                    category: ListedJob.Category(rawValue: row["category"]) ?? .private,
                    length: row["length"],
                    slots: row["slots"] == nil ? nil : slots
                )
                let placement = SchedulePlacement(
                    week: placementWeek,
                    jobID: row["placement_job_id"],
                    characterID: row["character_id"],
                    day: row["day"],
                    slot: row["slot"],
                    savedAt: row["saved_at"],
                    countedAt: row["counted_at"]
                )
                return SavedPlacement(job: job, placement: placement)
            }
        }
    }

    /// Saves what can be of `placements` into `week`; the rest come back with why.
    public func saveSchedule(
        characterID: String, week: CalendarDay, placements inputs: [PlacementInput],
        now: Date = Date(), timeZone: TimeZone
    ) throws -> ScheduleSave {
        let thisWeek = ScheduleRules.week(of: now)
        let nextWeek = thisWeek.adding(days: ScheduleRules.days)
        guard week == thisWeek || week == nextWeek else {
            return ScheduleSave(refused: inputs.map {
                RefusedPlacement(input: $0, reason: "这一周不能排")
            })
        }
        let idols = try idolIDs()
        let list = try jobList()
        return try userQueue.write { db in
            try Self.ensureWeekDrawn(db, week: week, idols: idols, jobs: list)
            let jobs = Dictionary(
                uniqueKeysWithValues: try Self.weeklyJobs(
                    db, week: week, characterID: characterID
                ).map { ($0.id, $0) }
            )
            var saved = try Self.placements(db, week: week, characterID: characterID)
            var result = ScheduleSave()
            for input in inputs {
                if let reason = Self.refusal(
                    input, jobs: jobs, saved: saved, week: week, thisWeek: thisWeek,
                    now: now, timeZone: timeZone
                ) {
                    result.refused.append(RefusedPlacement(input: input, reason: reason))
                    continue
                }
                let placement = SchedulePlacement(
                    week: week, jobID: input.jobID, characterID: characterID,
                    day: input.day, slot: input.slot, savedAt: Eidolon.timestamp(now)
                )
                try db.execute(
                    sql: """
                        INSERT INTO schedule_placements(week, job_id, character_id, day, slot, saved_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        week.stamp, input.jobID, characterID, input.day, input.slot,
                        placement.savedAt,
                    ]
                )
                saved.append(placement)
                result.saved.append(input)
            }
            return result
        }
    }

    // MARK: - Weeks and placements

    static func ensureWeekDrawn(
        _ db: Database, week: CalendarDay, idols: [String], jobs: [ListedJob]
    ) throws {
        let exists = try Bool.fetchOne(
            db, sql: "SELECT 1 FROM schedule_weeks WHERE week = ?", arguments: [week.stamp]
        ) ?? false
        guard !exists else { return }
        let drawn = try ScheduleRules.drawWeek(week: week, idols: idols, jobs: jobs)
        try db.execute(
            sql: "INSERT INTO schedule_weeks(week, drawn_at) VALUES (?, ?)",
            arguments: [week.stamp, Eidolon.timestamp(Date())]
        )
        for pair in drawn {
            let job = pair.job
            let id = "\(week.stamp):\(job.id)"
            try db.execute(
                sql: """
                    INSERT INTO weekly_jobs(
                        id, week, character_id, listed_id, name, note, category, length, slots
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, week.stamp, pair.characterID, job.id, job.name, job.note,
                    job.category.rawValue, job.length,
                    job.slots.map { $0.map { String($0.rawValue) }.joined(separator: ",") },
                ]
            )
        }
    }

    static func weeklyJobs(
        _ db: Database, week: CalendarDay, characterID: String?
    ) throws -> [WeeklyJob] {
        try weeklyJobs(db, weeks: [week], characterID: characterID)
    }

    static func weeklyJobs(
        _ db: Database, weeks: [CalendarDay], characterID: String?
    ) throws -> [WeeklyJob] {
        let marks = weeks.map(\.stamp)
        let placeholders = Array(repeating: "?", count: marks.count).joined(separator: ",")
        var sql = """
            SELECT id, week, character_id, listed_id, name, note, category, length, slots
            FROM weekly_jobs WHERE week IN (\(placeholders))
            """
        var arguments: [any DatabaseValueConvertible] = marks
        if let characterID {
            sql += " AND character_id = ?"
            arguments.append(characterID)
        }
        sql += " ORDER BY week, character_id, rowid"
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map { row in
            let slots = (row["slots"] as String?)?.split(separator: ",").compactMap {
                Int($0).flatMap(ScheduleSlot.init(rawValue:))
            }
            let weekParts = (row["week"] as String).split(separator: "-").compactMap { Int($0) }
            return WeeklyJob(
                id: row["id"],
                week: CalendarDay(
                    year: weekParts.count == 3 ? weekParts[0] : 0,
                    month: weekParts.count == 3 ? weekParts[1] : 1,
                    day: weekParts.count == 3 ? weekParts[2] : 1
                ),
                characterID: row["character_id"],
                listedID: row["listed_id"],
                name: row["name"],
                note: row["note"],
                category: ListedJob.Category(rawValue: row["category"]) ?? .private,
                length: row["length"],
                slots: row["slots"] == nil ? nil : slots
            )
        }
    }

    static func placements(
        _ db: Database, week: CalendarDay, characterID: String
    ) throws -> [SchedulePlacement] {
        try placementRows(db, characterID: characterID, weeks: [week])
    }

    static func placementRows(
        _ db: Database, characterID: String, weeks: [CalendarDay]
    ) throws -> [SchedulePlacement] {
        let marks = weeks.map(\.stamp)
        let placeholders = Array(repeating: "?", count: marks.count).joined(separator: ",")
        return try Row.fetchAll(
            db,
            sql: """
                SELECT week, job_id, character_id, day, slot, saved_at, counted_at
                FROM schedule_placements
                WHERE character_id = ? AND week IN (\(placeholders))
                ORDER BY week, day, slot
                """,
            arguments: StatementArguments([characterID] + marks)
        ).map(Self.placement(from:))
    }

    static func allPlacementRows(
        _ db: Database, weeks: [CalendarDay]
    ) throws -> [SchedulePlacement] {
        let marks = weeks.map(\.stamp)
        let placeholders = Array(repeating: "?", count: marks.count).joined(separator: ",")
        return try Row.fetchAll(
            db,
            sql: """
                SELECT week, job_id, character_id, day, slot, saved_at, counted_at
                FROM schedule_placements
                WHERE week IN (\(placeholders))
                ORDER BY week, day, slot
                """,
            arguments: StatementArguments(marks)
        ).map(Self.placement(from:))
    }

    static func placement(from row: Row) -> SchedulePlacement {
        SchedulePlacement(
            week: calendarDay(row["week"]),
            jobID: row["job_id"],
            characterID: row["character_id"],
            day: row["day"],
            slot: row["slot"],
            savedAt: row["saved_at"],
            countedAt: row["counted_at"]
        )
    }

    static func calendarDay(_ value: String) -> CalendarDay {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        return CalendarDay(
            year: parts.count == 3 ? parts[0] : 0,
            month: parts.count == 3 ? parts[1] : 1,
            day: parts.count == 3 ? parts[2] : 1
        )
    }

    static func refusal(
        _ input: PlacementInput, jobs: [String: WeeklyJob], saved: [SchedulePlacement],
        week: CalendarDay, thisWeek: CalendarDay, now: Date, timeZone: TimeZone
    ) -> String? {
        guard let job = jobs[input.jobID] else { return "这项工作不在这一周" }
        if saved.contains(where: { $0.jobID == input.jobID }) {
            return "这项工作已经保存过了"
        }
        guard (0..<7).contains(input.day), (0..<3).contains(input.slot) else {
            return "没有这个时间"
        }
        if input.slot + job.length > 3 {
            return job.length == 3 ? "一整天的工作只能从上午排" : "当天排不下"
        }
        for slot in input.slot..<(input.slot + job.length) {
            switch ScheduleRules.timeOf(
                local: now, timeZone: timeZone, thisWeek: thisWeek,
                week: week, day: input.day, slot: slot
            ) {
            case .past: return "已经过了"
            case .now: return "正在进行"
            case .future: break
            }
            if let slots = job.slots, !slots.contains(ScheduleSlot(rawValue: slot) ?? .morning) {
                return "只能排在\(Self.joined(slots.map(\.name)))"
            }
            for other in saved {
                let otherJob = jobs[other.jobID]
                let otherRange = other.slot..<(other.slot + (otherJob?.length ?? 1))
                if other.day == input.day, otherRange.contains(slot) {
                    return "格子里有别的工作"
                }
            }
        }
        return nil
    }

    static func joined(_ names: [String]) -> String {
        names.count == 1 ? names[0] : names.dropLast().joined(separator: "、") + "和" + names.last!
    }

    static func countDoneJobs(
        _ db: Database, now: Date, timeZone: TimeZone, thisWeek: CalendarDay
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT p.week, p.job_id, p.character_id, p.day, p.slot, j.length
                FROM schedule_placements p
                JOIN weekly_jobs j ON j.id = p.job_id
                WHERE p.counted_at IS NULL
                """
        )
        for row in rows {
            let parts = (row["week"] as String).split(separator: "-").compactMap { Int($0) }
            let week = CalendarDay(
                year: parts.count == 3 ? parts[0] : 0,
                month: parts.count == 3 ? parts[1] : 1,
                day: parts.count == 3 ? parts[2] : 1
            )
            guard ScheduleRules.isDone(
                local: now, timeZone: timeZone, thisWeek: thisWeek,
                week: week, day: row["day"], slot: row["slot"], length: row["length"]
            ) else { continue }
            let characterID: String = row["character_id"]
            let before = try Self.readAffinity(db, characterID: characterID, now: now)
            let after = before.stepped(ScheduleRules.jobDoneStep)
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, updated_at, cooling, gained_today, gained_on)
                    VALUES (?, ?, ?, ?, 0, NULL)
                    ON CONFLICT(character_id) DO UPDATE SET
                        value = excluded.value, updated_at = excluded.updated_at,
                        cooling = excluded.cooling
                    """,
                arguments: [
                    characterID, after.value, Eidolon.timestamp(now), after.cooling ? 1 : 0,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE schedule_placements SET counted_at = ?
                    WHERE week = ? AND job_id = ?
                    """,
                arguments: [Eidolon.timestamp(now), row["week"], row["job_id"]]
            )
        }
    }
}

/// Whose drafts of which week: the page keeps them apart as the producer switches between
/// characters and weeks.
public struct ScheduleDraftKey: Sendable, Hashable {
    public var characterID: String
    public var week: CalendarDay

    public init(characterID: String, week: CalendarDay) {
        self.characterID = characterID
        self.week = week
    }
}

/// The calendar page's view of the schedule (spec #51): the saved and drafted jobs of this
/// and next week, how many this week are unplaced, and whether the bundle lists jobs at all.
public struct ScheduleOverview: Sendable, Hashable {
    public var entries: [ScheduleCalendarEntry]
    public var pendingThisWeek: Int
    public var hasJobList: Bool

    public init(entries: [ScheduleCalendarEntry], pendingThisWeek: Int, hasJobList: Bool) {
        self.entries = entries
        self.pendingThisWeek = pendingThisWeek
        self.hasJobList = hasJobList
    }
}

/// Reading what the schedule keeps without the rest of `Eidolon`, for the bar.
public enum ScheduleStore {
    /// Her job the producer scheduled today and she has done, the latest if more than one.
    public static func doneTodayJob(
        _ db: Database, characterID: String, now: Date, timeZone: TimeZone
    ) throws -> WeeklyJob? {
        let thisWeek = ScheduleRules.week(of: now)
        let placements = try Eidolon.placementRows(
            db, characterID: characterID, weeks: [thisWeek]
        )
        let jobs = Dictionary(
            uniqueKeysWithValues: try Eidolon.weeklyJobs(
                db, weeks: [thisWeek], characterID: characterID
            ).map { ($0.id, $0) }
        )
        let today = ScheduleRules.localWeekday(now: now, timeZone: timeZone)
        var latest: WeeklyJob?
        for placement in placements where placement.day == today {
            guard let job = jobs[placement.jobID] else { continue }
            if ScheduleRules.isDone(
                local: now, timeZone: timeZone, thisWeek: thisWeek,
                week: placement.week, day: placement.day, slot: placement.slot,
                length: job.length
            ) {
                latest = job
            }
        }
        return latest
    }
}

/// What she is told of her schedule (upstream `schedule_lines`): the jobs the producer
/// placed, which are done and which is under way, and how to talk about them.
public enum SchedulePrompt {
    static let herJobs = "制作人给你排了这些工作（日程定了就不会再变；制作人在对话里说取消或改期，你还是按日程上的来）："
    static let underWay = "说话可以带着这个状态（抽空回、在休息），不用每句都提，说过就不再反复说。"
    static let about = "这些是你的制作人排的，你可以按你们的关系抱怨或期待；私人的安排也算他给你留出的时间。做完的工作你可以自己说过程和感受（顺不顺、累不累、小插曲），不要编后续的安排和结果（补拍、播出日期、因此接到的新工作、和别人的合作）。只在相关的时候提起，不在开头就说；同一项在这段对话里说过就不再主动提。别的偶像的安排你不清楚。"

    public static func lines(_ schedule: HerSchedule) -> [String] {
        guard !schedule.jobs.isEmpty else { return [] }
        var listed: [String] = []
        var underway: [String] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = schedule.timeZone
        let hour = calendar.component(.hour, from: schedule.local)
        for her in schedule.jobs {
            let whens = (her.slot..<(her.slot + her.job.length)).map {
                schedule.timeOf(week: her.week, day: her.day, slot: $0)
            }
            if whens.contains(.now), hour >= ScheduleRules.slotHours {
                let current = hour / ScheduleRules.slotHours - 1
                let slot = ScheduleSlot(rawValue: current)?.name ?? "上午"
                underway.append(
                    "现在（\(slot) \(ScheduleRules.slotHours * (current + 1))–"
                        + "\(ScheduleRules.slotHours * (current + 2)) 点）你正在\(her.job.name)："
                        + "\(her.job.note)。\(underWay)"
                )
                continue
            }
            let done = schedule.done(her) ? "（做完了）" : ""
            listed.append(
                "\(dayNamed(schedule, her.week, her.day))\(slotsNamed(her.slot, her.job.length))："
                    + "\(her.job.name)——\(her.job.note)\(done)"
            )
        }
        return [herJobs, listed.joined(separator: "\n"), underway.joined(separator: "\n"), about]
            .filter { !$0.isEmpty }
    }

    static func dayNamed(_ schedule: HerSchedule, _ week: CalendarDay, _ day: Int) -> String {
        let weekdays = "一二三四五六日"
        let named = (week > schedule.thisWeek ? "下周" : "周")
            + String(weekdays[weekdays.index(weekdays.startIndex, offsetBy: day)])
        let near = ["前天", "昨天", "今天", "明天", "后天"]
        let diff = week.adding(days: day).days(since: schedule.localDay)
        if (-2...2).contains(diff) { return "\(named)（\(near[diff + 2])）" }
        return named
    }

    static func slotsNamed(_ slot: Int, _ length: Int) -> String {
        ScheduleRules.slotsName(slot: slot, length: length)
    }
}
