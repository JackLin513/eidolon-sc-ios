import EidolonCore
import SwiftUI

/// The cycle page (spec #53): her records of periods, what they estimate, and the guide.
/// Everything here comes from the producer's records; her true cycle is never shown.
struct CyclesView: View {
    @Environment(AppModel.self) private var app

    @State private var characterID: String?
    @State private var month: CalendarPage.Month?
    @State private var selected: CalendarDay?
    @State private var records: [CycleRecord] = []
    @State private var estimate: CycleEstimate?
    @State private var form: FormState?
    @State private var loadError: String?
    @State private var isLoading = true
    @ScaledMetric(relativeTo: .subheadline) private var cellHeight = 52

    struct FormState: Identifiable {
        let id = UUID()
        var record: CycleRecord?
        var firstDay: CalendarDay
    }

    private var timeZone: TimeZone { app.producerTimeZone }
    private var character: CharacterConfig? {
        app.characters.first { $0.id == characterID }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let loadError {
                ContentUnavailableView {
                    Label("读不到记录", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else {
                content
            }
        }
        .navigationTitle("周期")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let today = CalendarPage.today(now: Date(), timeZone: timeZone)
                    let picked = selected ?? today
                    form = FormState(record: nil, firstDay: min(picked, today))
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("记一次经期")
            }
        }
        .task(id: characterID) { await load() }
        .sheet(item: $form) { form in
            NavigationStack {
                CycleRecordForm(
                    character: character,
                    editing: form.record,
                    firstDay: form.firstDay,
                    today: CalendarPage.today(now: Date(), timeZone: timeZone),
                    timeZone: timeZone
                ) {
                    Task { await load() }
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        if characterID == nil {
            characterID = app.characters.first?.id
            guard characterID != nil else {
                loadError = "内容包里没有角色"
                isLoading = false
                return
            }
            return
        }
        guard let characterID else { return }
        isLoading = records.isEmpty && month == nil
        let today = CalendarPage.today(now: Date(), timeZone: timeZone)
        if month == nil {
            month = CalendarPage.Month(
                year: today.year, month: today.month, timeZone: timeZone
            )
            selected = today
        }
        do {
            records = try await app.core.cycleRecords(characterID: characterID)
            estimate = try await app.core.cycleEstimate(
                characterID: characterID, now: Date(), timeZone: timeZone
            )
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - The page

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                characterBar
                summary
                if let month {
                    monthBar(month)
                    legend
                    grid(month)
                    selectedDay
                }
                recordsList
                guide
                privacy
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private var characterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(app.characters, id: \.id) { candidate in
                    let chosen = candidate.id == characterID
                    Button {
                        characterID = candidate.id
                        records = []
                        estimate = nil
                    } label: {
                        HStack(spacing: 6) {
                            avatar(candidate)
                            Text(candidate.nameZh ?? candidate.name)
                                .font(.caption.weight(chosen ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background {
                            Capsule().fill(
                                chosen ? Color.accentColor.opacity(0.2)
                                    : Color.secondary.opacity(0.1)
                            )
                        }
                        .overlay {
                            if chosen {
                                Capsule().stroke(Color.accentColor, lineWidth: 1.5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func avatar(_ candidate: CharacterConfig) -> some View {
        Group {
            if let image = app.avatar(for: candidate.id) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(String((candidate.nameZh ?? candidate.name).prefix(1)))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(character.map { ($0.nameZh ?? $0.name) + "的周期" } ?? "周期")
                .font(.headline)
            if let estimate {
                Text("周期约 \(estimate.cycle) 天 · 经期约 \(estimate.period) 天")
                    .font(.subheadline)
                    .monospacedDigit()
                if let next = estimate.periods.first {
                    Text("下一次推算：\(next.firstDay.month)月\(next.firstDay.day)日")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                if !estimate.reasons.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(estimate.reasons, id: \.self) { reason in
                            Text(label(reason))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background {
                                    Capsule().fill(Color.orange.opacity(0.15))
                                }
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if let offBy = estimate.offBy {
                    Text("过去的估算平均差 \(formatted(offBy)) 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("还没有记录。只记最近一次经期的第一天和天数，就会开始推算。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("没有记录时按 28 天周期、5 天经期示意：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CycleDiagramView()
            }
            Text("推算只用你记下的日期，不显示她的真实周期。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monthBar(_ month: CalendarPage.Month) -> some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.month = month.previous()
                    selected = nil
                }
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .accessibilityLabel("上个月")
            Spacer()
            Text(verbatim: "\(month.year)年\(month.month)月")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.month = month.next()
                    selected = nil
                }
            } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(!CycleCalendar.canShowNext(after: month, estimate: estimate))
            .accessibilityLabel("下个月")
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.recorded, text: "记录")
            legendItem(.period, text: "推算经期")
            legendItem(.premenstrual, text: "经前")
            Spacer(minLength: 0)
        }
    }

    private func legendItem(_ kind: CycleMarkKind, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(kind)).frame(width: 7, height: 7)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func grid(_ month: CalendarPage.Month) -> some View {
        let marks = CycleCalendar.marks(in: month, records: records, estimate: estimate)
        return VStack(spacing: 4) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                    Text(day)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(day == "日" ? .red.opacity(0.8) : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(month.cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day, marks: marks[day] ?? [], today: today)
                    } else {
                        Color.clear.frame(height: cellHeight)
                    }
                }
            }
        }
    }

    private var today: CalendarDay {
        CalendarPage.today(now: Date(), timeZone: timeZone)
    }

    private func dayCell(
        _ day: CalendarDay, marks: Set<CycleMarkKind>, today: CalendarDay
    ) -> some View {
        let isToday = day == today
        let isSelected = day == selected
        return Button {
            selected = day
        } label: {
            VStack(spacing: 3) {
                Text("\(day.day)")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                HStack(spacing: 3) {
                    ForEach(CycleMarkKind.allCases, id: \.self) { kind in
                        if marks.contains(kind) {
                            Capsule()
                                .fill(color(kind))
                                .frame(width: 5, height: 9)
                        }
                    }
                }
                .frame(height: 9)
            }
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
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
        .accessibilityLabel(accessibility(day, marks: marks))
    }

    private func accessibility(_ day: CalendarDay, marks: Set<CycleMarkKind>) -> String {
        var text = "\(day.year)年\(day.month)月\(day.day)日"
        let names = marks.map(label).sorted()
        if !names.isEmpty { text += "，" + names.joined(separator: "、") }
        return text
    }

    private var selectedDay: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let selected {
                Text("\(selected.month)月\(selected.day)日")
                    .font(.headline)
                let marks = CycleCalendar.marks(
                    in: month ?? CalendarPage.Month(
                        year: selected.year, month: selected.month, timeZone: timeZone
                    ),
                    records: records, estimate: estimate
                )[selected] ?? []
                if marks.isEmpty {
                    Text("这天没有经期或经前标记。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(marks.map(label).sorted().joined(separator: "、"))
                        .font(.subheadline)
                }
                let starting = records.filter { $0.firstDay == selected }
                ForEach(starting) { record in
                    Text("这天记下了一次经期，共 \(record.days) 天。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("点一天看那一天")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("记下的经期")
                .font(.headline)
            if records.isEmpty {
                Text("还没有记录。点右上角的加号，记下这次经期的第一天和天数。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records.sorted { $0.firstDay > $1.firstDay }) { record in
                    Button {
                        form = FormState(record: record, firstDay: record.firstDay)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "\(record.firstDay.year)年\(record.firstDay.month)月\(record.firstDay.day)日")
                                    .font(.subheadline)
                                Text("\(record.days) 天")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(record.firstDay.month)月\(record.firstDay.day)日，\(record.days) 天，点按修改"
                    )
                    Divider()
                }
            }
        }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("讲解")
                .font(.headline)
            ForEach(CycleGuide.blocks) { block in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(block.lead)
                            .font(.subheadline)
                        if block.hasDiagram {
                            CycleDiagramView()
                        }
                        ForEach(Array(block.parts.enumerated()), id: \.offset) { _, part in
                            VStack(alignment: .leading, spacing: 4) {
                                if let heading = part.heading {
                                    Text(heading)
                                        .font(.subheadline.weight(.semibold))
                                }
                                ForEach(Array(part.sentences.enumerated()), id: \.offset) { _, sentence in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(sentence.text)
                                            .font(.footnote)
                                        HStack(spacing: 8) {
                                            ForEach(sentence.sources, id: \.href) { source in
                                                Link(source.label, destination: URL(string: source.href)!)
                                                    .font(.caption2)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } label: {
                    Text(block.title)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var privacy: some View {
        Text("记录只留在这台设备上，不导出、不上传，也不写进对话或记忆。讲解是通用的健康信息，不能用来诊断。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    }

    private func color(_ kind: CycleMarkKind) -> Color {
        switch kind {
        case .recorded: .blue
        case .period: .pink
        case .premenstrual: .orange
        }
    }

    private func label(_ kind: CycleMarkKind) -> String {
        switch kind {
        case .recorded: "记录"
        case .period: "推算经期"
        case .premenstrual: "经前"
        }
    }

    private func label(_ reason: CycleReason) -> String {
        switch reason {
        case .once: "只记了一次"
        case .irregular: "不太规律"
        case .missed: "可能有漏记"
        case .late: "可能晚来"
        }
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// The 28-day example bar: period days 1–5, ovulation day 15, fertile days 10–16.
struct CycleDiagramView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 1) {
                ForEach(CycleGuide.diagramDays(), id: \.day) { day in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(color(day.kind))
                        .frame(height: 16)
                        .accessibilityLabel("第 \(day.day) 天，\(label(day.kind))")
                }
            }
            HStack {
                Text("第 1 天").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("第 15 天").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("第 28 天").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                key(.period, "经期")
                key(.fertile, "易孕期")
                key(.ovulation, "排卵日")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("28 天示意图：第 1 到 5 天经期，第 10 到 16 天易孕期，第 15 天排卵日")
    }

    private func key(_ kind: CycleDiagramKind, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5).fill(color(kind)).frame(width: 10, height: 8)
            Text(text)
        }
    }

    private func color(_ kind: CycleDiagramKind?) -> Color {
        switch kind {
        case .period: .pink
        case .fertile: .teal
        case .ovulation: .purple
        case nil: Color.secondary.opacity(0.2)
        }
    }

    private func label(_ kind: CycleDiagramKind?) -> String {
        switch kind {
        case .period: "经期"
        case .fertile: "易孕期"
        case .ovulation: "排卵日"
        case nil: "其他"
        }
    }
}

/// Add or change one of her periods; the day is the producer's calendar day.
private struct CycleRecordForm: View {
    let character: CharacterConfig?
    let editing: CycleRecord?
    let today: CalendarDay
    let timeZone: TimeZone
    var onChanged: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var days: Int
    @State private var error: String?
    @State private var saving = false
    @State private var confirmingDelete = false

    init(
        character: CharacterConfig?, editing: CycleRecord?, firstDay: CalendarDay,
        today: CalendarDay, timeZone: TimeZone, onChanged: @escaping () -> Void
    ) {
        self.character = character
        self.editing = editing
        self.today = today
        self.timeZone = timeZone
        self.onChanged = onChanged
        _date = State(initialValue: Self.date(firstDay, in: timeZone))
        _days = State(initialValue: editing?.days ?? CycleEstimateRules.typicalPeriod)
    }

    var body: some View {
        Form {
            Section {
                DatePicker(
                    "第一天", selection: $date, in: ...Self.endOf(today, in: timeZone),
                    displayedComponents: .date
                )
                Stepper(
                    "天数：\(days) 天", value: $days,
                    in: CycleEstimateRules.fewestDays...CycleEstimateRules.mostDays
                )
            } footer: {
                Text("记已经发生的那一次；天数在 3 到 8 天之间。记录之间不能重叠，更早或更晚的写另一条。")
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
            if editing != nil {
                Section {
                    Button("删除这条记录", role: .destructive) {
                        confirmingDelete = true
                    }
                }
            }
        }
        .navigationTitle(editing == nil ? "记一次经期" : "修改记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(saving || character == nil)
            }
        }
        .alert("删除这条记录？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) { Task { await delete() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删掉以后推算会按剩下的记录重算。")
        }
    }

    private func save() async {
        guard let character else { return }
        saving = true
        error = nil
        defer { saving = false }
        let day = Self.calendarDay(date, in: timeZone)
        do {
            if let editing {
                _ = try await app.core.changeCycleRecord(
                    id: editing.id, firstDay: day, days: days,
                    now: Date(), timeZone: timeZone
                )
            } else {
                _ = try await app.core.addCycleRecord(
                    characterID: character.id, firstDay: day, days: days,
                    now: Date(), timeZone: timeZone
                )
            }
            onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let editing else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await app.core.deleteCycleRecord(id: editing.id)
            onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func date(_ day: CalendarDay, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 12
        ))!
    }

    /// The end of the producer's today: a day after it cannot be picked.
    private static func endOf(_ day: CalendarDay, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day
        ))!
        return start.addingTimeInterval(86_399)
    }

    private static func calendarDay(_ date: Date, in timeZone: TimeZone) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(
            year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1
        )
    }
}
