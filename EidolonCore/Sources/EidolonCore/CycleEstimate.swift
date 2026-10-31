import Foundation
import GRDB

/// A period the producer wrote down (GLOSSARY.md「周期」): its first day and how many days.
public struct CycleRecord: Sendable, Hashable, Identifiable {
    public var id: String
    public var characterID: String
    public var firstDay: CalendarDay
    public var days: Int
    /// When it was first written down.
    public var recordedAt: String
    /// When it was last changed; the same as `recordedAt` until it is changed.
    public var updatedAt: String

    public init(
        id: String, characterID: String, firstDay: CalendarDay, days: Int,
        recordedAt: String, updatedAt: String? = nil
    ) {
        self.id = id
        self.characterID = characterID
        self.firstDay = firstDay
        self.days = days
        self.recordedAt = recordedAt
        self.updatedAt = updatedAt ?? recordedAt
    }
}

/// What the producer's records say of her cycle, worked out whenever it is asked and never
/// stored; her true cycle (`HerCycle`) is not read.
public struct EstimatedPeriod: Sendable, Hashable {
    public var firstDay: CalendarDay
    public var days: Int

    public init(firstDay: CalendarDay, days: Int) {
        self.firstDay = firstDay
        self.days = days
    }
}

public enum CycleReason: String, CaseIterable, Sendable, Hashable {
    case once
    case irregular
    case missed
    case late
}

public enum CycleToday: Sendable, Hashable {
    case recorded(day: Int)
    case estimated
    case premenstrual
}

public struct CycleEstimate: Sendable, Hashable {
    public var cycle: Int
    public var period: Int
    public var reasons: [CycleReason]
    public var periods: [EstimatedPeriod]
    /// How many days past estimates were off on average, to a tenth; nil from fewer than
    /// two compared.
    public var offBy: Double?
    public var today: CycleToday?

    public init(
        cycle: Int, period: Int, reasons: [CycleReason], periods: [EstimatedPeriod],
        offBy: Double?, today: CycleToday?
    ) {
        self.cycle = cycle
        self.period = period
        self.reasons = reasons
        self.periods = periods
        self.offBy = offBy
        self.today = today
    }
}

/// A record that cannot be written down, or one that is not there.
public enum CycleRecordError: Error, LocalizedError, Sendable, Equatable {
    case future
    case days
    case overlap(CalendarDay)
    case noSuchCharacter
    case noSuchRecord

    public var errorDescription: String? {
        switch self {
        case .future:
            "不能记未来"
        case .days:
            "天数应在 3 到 8 天之间"
        case let .overlap(day):
            "和 \(day.month)月\(day.day)日 那次重叠了，要改就编辑那一次"
        case .noSuchCharacter:
            "内容包里没有这位角色"
        case .noSuchRecord:
            "没有这条记录"
        }
    }
}

/// The estimate used by the cycle page, after LAPLACE Cycles (upstream `cycle_estimate.py`).
public enum CycleEstimateRules {
    public static let typicalCycle = 28
    public static let typicalPeriod = 5
    public static let gaps = 8
    public static let shortestGap = 15
    public static let longestGap = 60
    public static let anchor = 22...38
    public static let missedTimes = 1.6
    public static let foldedFrom = 45
    public static let irregular = 7
    public static let periods = 6
    public static let ahead = 3
    public static let premenstrual = 5
    public static let fewestDays = 3
    public static let mostDays = 8

    /// What is estimated from `records` on `today`; nil without a record.
    public static func estimate(
        records: [CycleRecord], today: CalendarDay
    ) -> CycleEstimate? {
        guard !records.isEmpty else { return nil }
        let sorted = records.sorted { $0.firstDay < $1.firstDay }
        let (cycle, gaps, cycleReasons) = cycle(sorted)
        var reasons = cycleReasons
        let period: Int
        if !gaps.isEmpty {
            period = rounded(median(sorted.suffix(periods).map { Double($0.days) }))
        } else {
            period = max(sorted[sorted.count - 1].days, typicalPeriod)
        }
        let first = sorted[sorted.count - 1].firstDay.adding(days: cycle)
        let estimated = (0..<ahead).map {
            EstimatedPeriod(firstDay: first.adding(days: cycle * $0), days: period)
        }
        if today > first { reasons.insert(.late) }
        return CycleEstimate(
            cycle: cycle,
            period: period,
            reasons: CycleReason.allCases.filter { reasons.contains($0) },
            periods: estimated,
            offBy: offBy(sorted),
            today: day(sorted, periods: estimated, today: today)
        )
    }

    private static func cycle(
        _ records: [CycleRecord]
    ) -> (Int, [Double], Set<CycleReason>) {
        guard records.count > 1 else {
            return (typicalCycle, [], [.once])
        }
        var reasons: Set<CycleReason> = []
        let all = zip(records, records.dropFirst()).map {
            Double($1.firstDay.days(since: $0.firstDay))
        }
        let days = Array(all.suffix(gaps))
        var gaps = days.filter { $0 >= Double(shortestGap) && $0 <= Double(longestGap) }
        if let least = gaps.min() {
            let anchor = min(max(least, Double(anchor.lowerBound)), Double(anchor.upperBound))
            gaps = gaps.filter { $0 < anchor * missedTimes }
        }
        if gaps.count < days.count { reasons.insert(.missed) }
        if (1...2).contains(gaps.count), gaps.allSatisfy({ $0 >= Double(foldedFrom) }) {
            gaps = gaps.map { $0 / max(($0 / Double(typicalCycle)).rounded(), 1) }
            reasons.insert(.missed)
        }
        guard !gaps.isEmpty else {
            return (typicalCycle, [], reasons)
        }
        if let least = gaps.min(), let most = gaps.max(), most - least > Double(irregular) {
            reasons.insert(.irregular)
        }
        return (rounded(median(gaps)), gaps, reasons)
    }

    private static func offBy(_ records: [CycleRecord]) -> Double? {
        var off: [Double] = []
        for n in 1..<records.count {
            let (estimated, _, _) = cycle(Array(records.prefix(n)))
            let gap = records[n].firstDay.days(since: records[n - 1].firstDay)
            if gap >= shortestGap, gap <= longestGap,
               Double(gap) < Double(estimated) * missedTimes {
                off.append(Double(abs(gap - estimated)))
            }
        }
        guard off.count >= 2 else { return nil }
        let mean = off.reduce(0, +) / Double(off.count)
        return (mean * 10 + 0.5).rounded(.down) / 10
    }

    private static func day(
        _ records: [CycleRecord], periods: [EstimatedPeriod], today: CalendarDay
    ) -> CycleToday? {
        for record in records {
            let into = today.days(since: record.firstDay)
            if into >= 0, into < record.days { return .recorded(day: into + 1) }
        }
        for period in periods {
            let into = today.days(since: period.firstDay)
            if into >= 0, into < period.days { return .estimated }
            if into >= -premenstrual, into < 0 { return .premenstrual }
        }
        return nil
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func rounded(_ days: Double) -> Int {
        Int((days + 0.5).rounded(.down))
    }
}

// MARK: - Her records in the user library

extension Eidolon {
    static let cycleRecordColumns =
        "id, character_id, first_day, days, recorded_at, updated_at"

    static func cycleRecords(_ db: Database, characterID: String) throws -> [CycleRecord] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT \(cycleRecordColumns) FROM cycle_records
                WHERE character_id = ? ORDER BY first_day
                """,
            arguments: [characterID]
        ).map(Self.record(from:))
    }

    static func cycleRecord(_ db: Database, id: String) throws -> CycleRecord? {
        try Row.fetchOne(
            db,
            sql: "SELECT \(cycleRecordColumns) FROM cycle_records WHERE id = ?",
            arguments: [id]
        ).map(Self.record(from:))
    }

    /// One character's records, by first day.
    public func cycleRecords(characterID: String) throws -> [CycleRecord] {
        try userQueue.read { db in try Self.cycleRecords(db, characterID: characterID) }
    }

    /// What her records estimate on the producer's day; nil without a record.
    public func cycleEstimate(
        characterID: String, now: Date = Date(), timeZone: TimeZone
    ) throws -> CycleEstimate? {
        CycleEstimateRules.estimate(
            records: try cycleRecords(characterID: characterID),
            today: CalendarPage.today(now: now, timeZone: timeZone)
        )
    }

    @discardableResult
    public func addCycleRecord(
        characterID: String, firstDay: CalendarDay, days: Int,
        now: Date = Date(), timeZone: TimeZone
    ) throws -> CycleRecord {
        let today = CalendarPage.today(now: now, timeZone: timeZone)
        guard try characters().contains(where: { $0.id == characterID }) else {
            throw CycleRecordError.noSuchCharacter
        }
        return try userQueue.write { db in
            let existing = try Self.cycleRecords(db, characterID: characterID)
            try Self.check(
                firstDay: firstDay, days: days, today: today, existing: existing, id: nil
            )
            let stamp = Eidolon.timestamp(now)
            let record = CycleRecord(
                id: UUID().uuidString, characterID: characterID,
                firstDay: firstDay, days: days, recordedAt: stamp, updatedAt: stamp
            )
            try Self.insert(record, into: db)
            return record
        }
    }

    @discardableResult
    public func changeCycleRecord(
        id: String, firstDay: CalendarDay, days: Int,
        now: Date = Date(), timeZone: TimeZone
    ) throws -> CycleRecord {
        let today = CalendarPage.today(now: now, timeZone: timeZone)
        return try userQueue.write { db in
            guard let old = try Self.cycleRecord(db, id: id) else {
                throw CycleRecordError.noSuchRecord
            }
            let existing = try Self.cycleRecords(db, characterID: old.characterID)
            try Self.check(
                firstDay: firstDay, days: days, today: today, existing: existing, id: id
            )
            let record = CycleRecord(
                id: id, characterID: old.characterID, firstDay: firstDay, days: days,
                recordedAt: old.recordedAt, updatedAt: Eidolon.timestamp(now)
            )
            try db.execute(
                sql: """
                    UPDATE cycle_records SET first_day = ?, days = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [firstDay.stamp, days, record.updatedAt, id]
            )
            return record
        }
    }

    public func deleteCycleRecord(id: String) throws {
        try userQueue.write { db in
            try db.execute(sql: "DELETE FROM cycle_records WHERE id = ?", arguments: [id])
            guard db.changesCount > 0 else { throw CycleRecordError.noSuchRecord }
        }
    }

    static func record(from row: Row) -> CycleRecord {
        let parts = (row["first_day"] as String).split(separator: "-").compactMap { Int($0) }
        return CycleRecord(
            id: row["id"],
            characterID: row["character_id"],
            firstDay: CalendarDay(
                year: parts.count == 3 ? parts[0] : 0,
                month: parts.count == 3 ? parts[1] : 1,
                day: parts.count == 3 ? parts[2] : 1
            ),
            days: row["days"],
            recordedAt: row["recorded_at"],
            updatedAt: row["updated_at"]
        )
    }

    static func insert(_ record: CycleRecord, into db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO cycle_records(
                    id, character_id, first_day, days, recorded_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                record.id, record.characterID, record.firstDay.stamp, record.days,
                record.recordedAt, record.updatedAt,
            ]
        )
    }

    static func check(
        firstDay: CalendarDay, days: Int, today: CalendarDay,
        existing: [CycleRecord], id: String?
    ) throws {
        guard firstDay <= today else { throw CycleRecordError.future }
        guard (CycleEstimateRules.fewestDays...CycleEstimateRules.mostDays).contains(days)
        else { throw CycleRecordError.days }
        for record in existing where record.id != id {
            let ends = firstDay.adding(days: days)
            let otherEnds = record.firstDay.adding(days: record.days)
            if firstDay < otherEnds, record.firstDay < ends {
                throw CycleRecordError.overlap(record.firstDay)
            }
        }
    }
}
