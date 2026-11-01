import Foundation

/// One character as the system-calendar export sees her: her name and birthday (spec #56).
public struct CalendarExportCharacter: Sendable, Hashable {
    public var id: String
    public var name: String
    public var birthday: Birthday?

    public init(id: String, name: String, birthday: Birthday? = nil) {
        self.id = id
        self.name = name
        self.birthday = birthday
    }
}

/// One saved placement and the job it places, with her name for the event title.
public struct CalendarExportJob: Sendable, Hashable {
    public var job: WeeklyJob
    public var placement: SchedulePlacement
    public var characterName: String

    public init(job: WeeklyJob, placement: SchedulePlacement, characterName: String) {
        self.job = job
        self.placement = placement
        self.characterName = characterName
    }
}

/// Everything the export should mirror: her birthdays, the producer's, and every saved job.
public struct CalendarExportSource: Sendable, Hashable {
    public var characters: [CalendarExportCharacter]
    public var producerBirthday: Birthday?
    public var jobs: [CalendarExportJob]
    public var timeZone: TimeZone

    public init(
        characters: [CalendarExportCharacter],
        producerBirthday: Birthday?,
        jobs: [CalendarExportJob],
        timeZone: TimeZone
    ) {
        self.characters = characters
        self.producerBirthday = producerBirthday
        self.jobs = jobs
        self.timeZone = timeZone
    }
}

/// One event Eidolon expects the system calendar to hold. `marker` is its stable identity.
public struct CalendarExportEvent: Sendable, Hashable {
    public var marker: String
    public var title: String
    public var notes: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var repeatsYearly: Bool
    /// For an all-day birthday: the month and day as `MM-DD`, which is what repeats. System
    /// calendars normalize an all-day event's dates to local midnight and 23:59:59, so the
    /// absolute dates are not compared for these.
    public var allDayKey: String?

    public init(
        marker: String, title: String, notes: String = "", start: Date, end: Date,
        isAllDay: Bool, repeatsYearly: Bool, allDayKey: String? = nil
    ) {
        self.marker = marker
        self.title = title
        self.notes = notes
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.repeatsYearly = repeatsYearly
        self.allDayKey = allDayKey
    }

    /// Whether this event is one Eidolon wrote, rather than the producer's own.
    public var isMarked: Bool {
        marker.hasPrefix(CalendarExportEvent.markerPrefix)
    }

    public static let markerPrefix = "eidolon://export/"
}

/// An event the calendar already holds; `id` is the calendar's own identifier.
public struct CalendarExportStoredEvent: Sendable, Hashable, Identifiable {
    public var id: String
    public var event: CalendarExportEvent

    public init(id: String, event: CalendarExportEvent) {
        self.id = id
        self.event = event
    }
}

/// An existing event whose fields no longer match what Eidolon expects.
public struct CalendarExportUpdate: Sendable, Hashable {
    public var id: String
    public var event: CalendarExportEvent

    public init(id: String, event: CalendarExportEvent) {
        self.id = id
        self.event = event
    }
}

/// What a sync will do, in order: create/update expected events, then delete strays.
public struct CalendarExportPlan: Sendable, Hashable {
    public var creates: [CalendarExportEvent]
    public var updates: [CalendarExportUpdate]
    /// Calendar identifiers of marked events no longer expected.
    public var deletes: [String]

    public init(
        creates: [CalendarExportEvent] = [], updates: [CalendarExportUpdate] = [],
        deletes: [String] = []
    ) {
        self.creates = creates
        self.updates = updates
        self.deletes = deletes
    }
}

/// What can be written to a system calendar, kept behind this seam so EventKit stays in the app.
public protocol CalendarExportStore: Sendable {
    func storedEvents(for expected: [CalendarExportEvent]) async throws -> [CalendarExportStoredEvent]
    func create(_ event: CalendarExportEvent) async throws
    func update(id: String, to event: CalendarExportEvent) async throws
    func delete(id: String) async throws
}

public enum CalendarExportBuilder {
    /// The events the app's birthdays and saved jobs should have in the system calendar.
    public static func events(from source: CalendarExportSource) -> [CalendarExportEvent] {
        var events: [CalendarExportEvent] = []
        for character in source.characters {
            guard let birthday = character.birthday,
                  let start = day(2024, birthday.month, birthday.day, hour: 0, in: source.timeZone),
                  let end = day(2024, birthday.month, birthday.day + 1, hour: 0, in: source.timeZone)
            else { continue }
            events.append(CalendarExportEvent(
                marker: marker("/birthday/character/\(character.id)"),
                title: "\(character.name) 生日",
                start: start,
                end: end,
                isAllDay: true,
                repeatsYearly: true,
                allDayKey: birthday.key
            ))
        }
        if let birthday = source.producerBirthday,
           let start = day(2024, birthday.month, birthday.day, hour: 0, in: source.timeZone),
           let end = day(2024, birthday.month, birthday.day + 1, hour: 0, in: source.timeZone) {
            events.append(CalendarExportEvent(
                marker: marker("/birthday/producer"),
                title: "制作人的生日",
                start: start,
                end: end,
                isAllDay: true,
                repeatsYearly: true,
                allDayKey: birthday.key
            ))
        }
        for saved in source.jobs {
            let placement = saved.placement
            guard (0..<3).contains(placement.slot),
                  (1...3).contains(saved.job.length),
                  let start = day(
                      placement.week.year, placement.week.month,
                      placement.week.day + placement.day,
                      hour: 6 + placement.slot * 6, in: source.timeZone
                  )
            else { continue }
            let end = start.addingTimeInterval(TimeInterval(saved.job.length * 6 * 3600))
            events.append(CalendarExportEvent(
                marker: marker("/schedule/\(saved.job.id)"),
                title: "\(saved.characterName) · \(saved.job.name)",
                notes: "\(saved.job.note)\n\n制作人排的工作",
                start: start,
                end: end,
                isAllDay: false,
                repeatsYearly: false
            ))
        }
        return events
    }

    private static func day(
        _ year: Int, _ month: Int, _ day: Int, hour: Int, in timeZone: TimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        ))
    }

    private static func marker(_ path: String) -> String {
        var components = URLComponents()
        components.scheme = "eidolon"
        components.host = "export"
        components.path = path
        return components.url?.absoluteString ?? "eidolon://export\(path)"
    }
}

public enum CalendarExportPlanner {
    /// Reconciles what should be there with what is: creates, updates, then deletions.
    /// Events without an Eidolon marker are never touched.
    public static func plan(
        expected: [CalendarExportEvent], existing: [CalendarExportStoredEvent]
    ) -> CalendarExportPlan {
        var byMarker: [String: [CalendarExportStoredEvent]] = [:]
        for event in existing where event.event.isMarked {
            byMarker[event.event.marker, default: []].append(event)
        }

        var plan = CalendarExportPlan()
        var used = Set<String>()
        var seenMarkers = Set<String>()
        for wanted in expected where seenMarkers.insert(wanted.marker).inserted {
            guard let candidate = byMarker[wanted.marker]?.first(where: { !used.contains($0.id) })
            else {
                plan.creates.append(wanted)
                continue
            }
            used.insert(candidate.id)
            if !same(candidate.event, wanted) {
                plan.updates.append(CalendarExportUpdate(id: candidate.id, event: wanted))
            }
        }
        for event in existing
        where event.event.isMarked && !used.contains(event.id) {
            plan.deletes.append(event.id)
        }
        return plan
    }

    private static func same(_ left: CalendarExportEvent, _ right: CalendarExportEvent) -> Bool {
        guard left.marker == right.marker,
              left.title == right.title,
              left.notes == right.notes,
              left.isAllDay == right.isAllDay,
              left.repeatsYearly == right.repeatsYearly
        else { return false }
        if left.isAllDay {
            return left.allDayKey == right.allDayKey
        }
        return left.start == right.start && left.end == right.end
    }
}

public enum CalendarExportSynchronizer {
    /// Writes the plan to `store`. Creates and updates come before deletes, so a failure
    /// while writing leaves the calendar's existing events rather than emptying it.
    @discardableResult
    public static func sync(
        expected: [CalendarExportEvent], store: any CalendarExportStore
    ) async throws -> CalendarExportPlan {
        let existing = try await store.storedEvents(for: expected)
        let plan = CalendarExportPlanner.plan(expected: expected, existing: existing)
        for event in plan.creates {
            try await store.create(event)
        }
        for update in plan.updates {
            try await store.update(id: update.id, to: update.event)
        }
        for id in plan.deletes {
            try await store.delete(id: id)
        }
        return plan
    }
}
