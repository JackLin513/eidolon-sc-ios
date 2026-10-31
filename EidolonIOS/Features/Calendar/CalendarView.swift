import EidolonCore
import SwiftUI

/// The calendar page (spec #49): a month of her birthdays, the producer's birthday and
/// Japan's holidays, with the kinds that matter to the producer kept on this device.
struct CalendarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var month: CalendarPage.Month?
    @State private var selected: CalendarDay?
    @State private var kinds = CalendarView.storedKinds()

    private static let kindsKey = "calendar.kinds"

    var body: some View {
        NavigationStack {
            Group {
                if let month {
                    content(month)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            guard month == nil else { return }
            let today = CalendarPage.today(now: Date(), timeZone: app.producerTimeZone)
            month = CalendarPage.Month(
                year: today.year,
                month: today.month,
                timeZone: app.producerTimeZone
            )
            selected = today
        }
    }

    private func content(_ month: CalendarPage.Month) -> some View {
        let today = CalendarPage.today(now: Date(), timeZone: app.producerTimeZone)
        let all = CalendarPage.events(
            in: month,
            characters: app.characters,
            producerBirthday: app.producerProfile.birthday,
            holidays: app.holidays
        )
        let shown = all.filter { kinds.contains($0.kind) }
        let byDay: [CalendarDay: [CalendarEvent]] = Dictionary(grouping: shown, by: \.day)
        return ScrollView {
            VStack(spacing: 16) {
                monthBar(month)
                filters
                weekdays
                grid(month, today: today, byDay: byDay)
                Divider()
                dayList(selected: selected, byDay: byDay)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func monthBar(_ month: CalendarPage.Month) -> some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.month = month.previous()
                    selected = nil
                }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("上个月")
            Spacer()
            Text("\(month.year)年\(month.month)月")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.month = month.next()
                    selected = nil
                }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("下个月")
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            ForEach(CalendarKind.allCases, id: \.self) { kind in
                let on = kinds.contains(kind)
                Button {
                    if on { kinds.remove(kind) } else { kinds.insert(kind) }
                    saveKinds()
                } label: {
                    Text(label(kind))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background {
                            Capsule().fill(on ? color(kind) : Color.secondary.opacity(0.12))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityValue(on ? "显示" : "隐藏")
            }
            Spacer(minLength: 0)
        }
    }

    private var weekdays: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                Text(day)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(day == "日" ? .red.opacity(0.8) : .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func grid(
        _ month: CalendarPage.Month,
        today: CalendarDay,
        byDay: [CalendarDay: [CalendarEvent]]
    ) -> some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(month.cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day, today: today, events: byDay[day] ?? [])
                } else {
                    Color.clear.frame(height: 52)
                }
            }
        }
    }

    private func dayCell(
        _ day: CalendarDay,
        today: CalendarDay,
        events: [CalendarEvent]
    ) -> some View {
        let isToday = day == today
        let isSelected = day == selected
        return Button {
            selected = day
        } label: {
            VStack(spacing: 3) {
                Text("\(day.day)")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                HStack(spacing: 2) {
                    ForEach(events.prefix(3)) { event in
                        Circle()
                            .fill(color(event.kind))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                } else if isToday {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility(day, events: events))
    }

    private func dayList(
        selected: CalendarDay?,
        byDay: [CalendarDay: [CalendarEvent]]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selected {
                Text("\(selected.month)月\(selected.day)日")
                    .font(.headline)
                let events = byDay[selected] ?? []
                if events.isEmpty {
                    Text("这天没有安排")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        eventRow(event)
                    }
                }
            } else {
                Text("点一天看那一天")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color(event.kind))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline)
                Text(label(event.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    }

    private func label(_ kind: CalendarKind) -> String {
        switch kind {
        case .character: return "她的生日"
        case .producer: return "制作人生日"
        case .holiday: return "节假日"
        }
    }

    private func color(_ kind: CalendarKind) -> Color {
        switch kind {
        case .character: return .pink
        case .producer: return .orange
        case .holiday: return .green
        }
    }

    private func accessibility(_ day: CalendarDay, events: [CalendarEvent]) -> String {
        let date = "\(day.year)年\(day.month)月\(day.day)日"
        guard !events.isEmpty else { return date }
        return date + "，" + events.map(\.title).joined(separator: "、")
    }

    private func saveKinds() {
        UserDefaults.standard.set(kinds.map(\.rawValue), forKey: Self.kindsKey)
    }

    static func storedKinds() -> Set<CalendarKind> {
        guard let raw = UserDefaults.standard.stringArray(forKey: kindsKey) else {
            return Set(CalendarKind.allCases)
        }
        return Set(raw.compactMap(CalendarKind.init(rawValue:)))
    }
}
