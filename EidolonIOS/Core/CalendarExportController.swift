import EventKit
import EidolonCore
import Foundation
import Observation

/// The preferences kept beside the export (spec #56): not part of the user library.
enum CalendarExportPreferences {
    static let enabledKey = "calendarExport.enabled"
    static let calendarIDKey = "calendarExport.calendarID"
    static let lastSyncKey = "calendarExport.lastSync"
    static let lastErrorKey = "calendarExport.lastError"
}

enum CalendarExportError: LocalizedError, Equatable {
    case accessDenied
    case noCalendarSource
    case eventGone

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "没有完整访问日历的权限。请在系统设置 → 隐私与安全性 → 日历里允许 Eidolon。"
        case .noCalendarSource:
            return "这台设备没有可写的日历来源，暂时不能创建 Eidolon 日历。"
        case .eventGone:
            return "要更新的日历事件已经不在了。"
        }
    }
}

/// EventKit behind the core synchronizer's seam. The store reads and writes only the
/// dedicated Eidolon calendar; events without an `eidolon://export/` marker are never touched.
actor EventKitCalendarStore: CalendarExportStore {
    static let calendarTitle = "Eidolon"
    private let store = EKEventStore()
    private var calendar: EKCalendar?

    /// Asks for full calendar access once; a denied answer throws.
    func requestAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { throw CalendarExportError.accessDenied }
        default:
            throw CalendarExportError.accessDenied
        }
    }

    func storedEvents(for expected: [CalendarExportEvent]) async throws -> [CalendarExportStoredEvent] {
        try await requestAccess()
        let calendar = try ensureCalendar()
        var seen = Set<String>()
        var events: [CalendarExportStoredEvent] = []
        for year in queryYears(for: expected) {
            for occurrence in store.events(matching: predicate(in: calendar, year: year)) {
                let id = occurrence.calendarItemIdentifier
                guard seen.insert(id).inserted else { continue }
                let event = (store.calendarItem(withIdentifier: id) as? EKEvent) ?? occurrence
                guard let marker = event.url?.absoluteString,
                      marker.hasPrefix(CalendarExportEvent.markerPrefix)
                else { continue }
                events.append(CalendarExportStoredEvent(id: id, event: converted(event)))
            }
        }
        return events.sorted { $0.event.marker < $1.event.marker }
    }

    func create(_ event: CalendarExportEvent) async throws {
        try await requestAccess()
        let item = EKEvent(eventStore: store)
        apply(event, to: item, calendar: try ensureCalendar())
        try store.save(item, span: .thisEvent, commit: true)
    }

    func update(id: String, to event: CalendarExportEvent) async throws {
        try await requestAccess()
        guard let item = (store.calendarItem(withIdentifier: id) as? EKEvent)
            ?? store.event(withIdentifier: id)
        else {
            throw CalendarExportError.eventGone
        }
        apply(event, to: item, calendar: try ensureCalendar())
        let span: EKSpan = item.recurrenceRules?.isEmpty == false ? .futureEvents : .thisEvent
        try store.save(item, span: span, commit: true)
    }

    func delete(id: String) async throws {
        try await requestAccess()
        guard let item = (store.calendarItem(withIdentifier: id) as? EKEvent)
            ?? store.event(withIdentifier: id)
        else { return }
        let span: EKSpan = item.recurrenceRules?.isEmpty == false ? .futureEvents : .thisEvent
        try store.remove(item, span: span, commit: true)
    }

    /// Removes only events carrying Eidolon's marker, returning how many were removed.
    func deleteMarkedEvents(for expected: [CalendarExportEvent]) async throws -> Int {
        try await requestAccess()
        let calendar = try ensureCalendar()
        var seen = Set<String>()
        var removed = 0
        for year in queryYears(for: expected) {
            for occurrence in store.events(matching: predicate(in: calendar, year: year)) {
                let id = occurrence.calendarItemIdentifier
                guard seen.insert(id).inserted else { continue }
                let item = (store.calendarItem(withIdentifier: id) as? EKEvent) ?? occurrence
                guard item.url?.absoluteString.hasPrefix(CalendarExportEvent.markerPrefix) == true
                else { continue }
                let span: EKSpan = item.recurrenceRules?.isEmpty == false ? .futureEvents : .thisEvent
                try store.remove(item, span: span, commit: true)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - The Eidolon calendar

    private func ensureCalendar() throws -> EKCalendar {
        let defaults = UserDefaults.standard
        if let calendar,
           store.calendar(withIdentifier: calendar.calendarIdentifier) != nil,
           calendar.allowsContentModifications {
            return calendar
        }
        if let id = defaults.string(forKey: CalendarExportPreferences.calendarIDKey),
           let found = store.calendar(withIdentifier: id),
           found.allowsContentModifications {
            calendar = found
            return found
        }
        if let found = store.calendars(for: .event).first(where: {
            $0.title == Self.calendarTitle && $0.allowsContentModifications
        }) {
            calendar = found
            defaults.set(found.calendarIdentifier, forKey: CalendarExportPreferences.calendarIDKey)
            return found
        }

        let source = store.sources.first { $0.sourceType == .local }
            ?? store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .calDAV }
            ?? store.sources.first
        guard let source else { throw CalendarExportError.noCalendarSource }

        let made = EKCalendar(for: .event, eventStore: store)
        made.title = Self.calendarTitle
        made.source = source
        try store.saveCalendar(made, commit: true)
        calendar = made
        defaults.set(made.calendarIdentifier, forKey: CalendarExportPreferences.calendarIDKey)
        return made
    }

    /// The years worth reading: every expected event's year, plus this one and the next for
    /// repeating birthdays and for events a previous sync left behind. EventKit stops
    /// returning anything for a range wide enough to span many years, so each year is asked
    /// for on its own.
    private func queryYears(for expected: [CalendarExportEvent]) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var years = Set<Int>()
        for event in expected {
            years.insert(calendar.component(.year, from: event.start))
            if !event.isAllDay {
                years.insert(calendar.component(.year, from: event.end))
            }
        }
        let now = calendar.component(.year, from: Date())
        years.insert(now)
        years.insert(now + 1)
        guard let first = years.min(), let last = years.max() else { return [] }
        return Array(first...last)
    }

    private func predicate(in calendar: EKCalendar, year: Int) -> NSPredicate {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        var calendarWithZone = Calendar(identifier: .gregorian)
        calendarWithZone.timeZone = .current
        let start = calendarWithZone.date(from: components)!
        let end = calendarWithZone.date(byAdding: .year, value: 1, to: start)!
        return store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
    }

    private func apply(
        _ event: CalendarExportEvent, to item: EKEvent, calendar: EKCalendar
    ) {
        item.calendar = calendar
        item.title = event.title
        item.notes = event.notes.isEmpty ? nil : event.notes
        item.startDate = event.start
        item.endDate = event.end
        item.isAllDay = event.isAllDay
        item.url = URL(string: event.marker)
        item.recurrenceRules = event.repeatsYearly
            ? [EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)]
            : nil
    }

    private func converted(_ event: EKEvent) -> CalendarExportEvent {
        var allDayKey: String?
        if event.isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = event.timeZone ?? .current
            let parts = calendar.dateComponents([.month, .day], from: event.startDate)
            allDayKey = String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
        }
        return CalendarExportEvent(
            marker: event.url?.absoluteString ?? "",
            title: event.title ?? "",
            notes: event.notes ?? "",
            start: event.startDate,
            end: event.endDate ?? event.startDate,
            isAllDay: event.isAllDay,
            repeatsYearly: event.recurrenceRules?.contains {
                $0.frequency == .yearly && $0.interval == 1
            } ?? false,
            allDayKey: allDayKey
        )
    }
}

/// The export's observable state for settings (spec #56). Syncs happen one at a time.
@MainActor
@Observable
final class CalendarExportController {
    private(set) var enabled: Bool
    private(set) var syncing = false
    private(set) var deleting = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var authorizationDenied = false

    private let store: EventKitCalendarStore
    private let defaults = UserDefaults.standard

    init(store: EventKitCalendarStore = EventKitCalendarStore()) {
        self.store = store
        enabled = defaults.bool(forKey: CalendarExportPreferences.enabledKey)
        lastSyncedAt = defaults.object(forKey: CalendarExportPreferences.lastSyncKey) as? Date
        lastError = defaults.string(forKey: CalendarExportPreferences.lastErrorKey)
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationDenied = status == .denied || status == .restricted
    }

    func setEnabled(_ on: Bool, source: CalendarExportSource) async {
        guard on != enabled else { return }
        guard on else {
            enabled = false
            defaults.set(false, forKey: CalendarExportPreferences.enabledKey)
            return
        }
        do {
            try await store.requestAccess()
            enabled = true
            defaults.set(true, forKey: CalendarExportPreferences.enabledKey)
            await sync(source: source)
        } catch {
            enabled = false
            defaults.set(false, forKey: CalendarExportPreferences.enabledKey)
            record(error)
        }
    }

    func syncIfEnabled(source: CalendarExportSource) async {
        guard enabled else { return }
        await sync(source: source)
    }

    func sync(source: CalendarExportSource) async {
        guard enabled, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let expected = CalendarExportBuilder.events(from: source)
            try await CalendarExportSynchronizer.sync(expected: expected, store: store)
            lastSyncedAt = Date()
            lastError = nil
            authorizationDenied = false
            defaults.set(lastSyncedAt, forKey: CalendarExportPreferences.lastSyncKey)
            defaults.removeObject(forKey: CalendarExportPreferences.lastErrorKey)
        } catch {
            record(error)
            if error as? CalendarExportError == .accessDenied {
                enabled = false
                defaults.set(false, forKey: CalendarExportPreferences.enabledKey)
                authorizationDenied = true
            }
        }
    }

    func deleteEvents(source: CalendarExportSource) async {
        guard !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            try await store.requestAccess()
            let expected = CalendarExportBuilder.events(from: source)
            _ = try await store.deleteMarkedEvents(for: expected)
            lastError = nil
            authorizationDenied = false
            defaults.removeObject(forKey: CalendarExportPreferences.lastErrorKey)
        } catch {
            record(error)
            if error as? CalendarExportError == .accessDenied {
                authorizationDenied = true
            }
        }
    }

    private func record(_ error: any Error) {
        lastError = error.localizedDescription
        authorizationDenied = (error as? CalendarExportError) == .accessDenied
        defaults.set(lastError, forKey: CalendarExportPreferences.lastErrorKey)
    }
}
