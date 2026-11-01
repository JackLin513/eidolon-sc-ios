import EidolonCore
import SwiftUI

/// A week's board for one character (spec #51): her jobs drawn for the week, a 7 × 3 grid,
/// and drafts placed by picking a card and then a cell. Saved placements are locked.
struct ScheduleBoardView: View {
    /// The character the page opens on; nil picks the first.
    var initialCharacterID: String?
    /// Drafts and save refusals, kept apart by character and week and shared with the
    /// calendar page so both pages see the same unsaved work.
    @Binding var book: ScheduleDraftBook

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var characterID: String?
    @State private var weekOffset = 0
    @State private var board: ScheduleBoard?
    @State private var planner: SchedulePlanner?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var saving = false
    @State private var switching = false
    @State private var notice: String?
    @State private var inspected: ScheduleCell?
    /// A cell's height, scaled with the text size; the seven days share a row's width.
    @ScaledMetric(relativeTo: .caption2) private var cellHeight = 48

    private var thisWeek: CalendarDay { ScheduleRules.week(of: Date()) }
    private var week: CalendarDay { thisWeek.adding(days: ScheduleRules.days * weekOffset) }

    private var key: ScheduleDraftKey? {
        characterID.map { ScheduleDraftKey(characterID: $0, week: week) }
    }

    private var character: CharacterConfig? {
        app.characters.first { $0.id == characterID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if let loadError {
                    ContentUnavailableView {
                        Label("读不到日程", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                } else {
                    content
                }
            }
            .navigationTitle("她的日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let planner, app.hasJobList, !planner.board.jobs.isEmpty {
                    saveBar(planner)
                }
            }
        }
        .task(id: taskID) { await load() }
        .alert(item: $inspected) { cell in
            inspectedAlert(cell)
        }
    }

    private var taskID: String {
        "\(initialCharacterID ?? "")|\(characterID ?? "")|\(weekOffset)"
    }

    // MARK: - Loading

    private func load() async {
        if characterID == nil {
            characterID = initialCharacterID
                ?? app.characters.first?.id
            guard characterID != nil else {
                loadError = "内容包里没有角色"
                isLoading = false
                switching = false
                return
            }
            return
        }
        guard let characterID, let key else { return }
        isLoading = board == nil
        do {
            let now = Date()
            let timeZone = app.producerTimeZone
            let fresh = try await app.core.scheduleBoard(
                characterID: characterID, week: week, now: now, timeZone: timeZone
            )
            apply(fresh, at: now, key: key)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
        switching = false
    }

    /// Reloads the week after a save, keeping unsaved drafts and their reasons.
    private func reloadBoard() async {
        guard let characterID, let key else { return }
        do {
            let now = Date()
            let fresh = try await app.core.scheduleBoard(
                characterID: characterID, week: week, now: now,
                timeZone: app.producerTimeZone
            )
            apply(fresh, at: now, key: key)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Builds the planner from a week as it now is, keeping this page's drafts and refusals.
    private func apply(_ fresh: ScheduleBoard, at now: Date, key: ScheduleDraftKey) {
        board = fresh
        planner = SchedulePlanner(
            board: fresh, now: now, timeZone: app.producerTimeZone, thisWeek: thisWeek,
            drafts: book.drafts(for: key), selectedJobID: nil, reasons: book.reasons(for: key)
        )
    }

    // MARK: - The page

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                characterBar
                weekBar
                if !app.hasJobList {
                    emptyCard(
                        title: "内容包里没有工作清单",
                        body: "这是旧格式的内容包。用新版导出工具重新导出（格式 4），再导入一次。"
                    )
                } else if let planner {
                    if planner.board.jobs.isEmpty {
                        emptyCard(title: "这周没有工作", body: "这一周没有抽到工作，下周再来看看。")
                    } else {
                        weekGrid(planner)
                        pendingSummary(planner)
                        cardList(planner)
                        if planner.pendingCount == planner.board.jobs.count, !planner.hasDrafts {
                            Text("还没排工作：点一张工作卡，再点一个空闲的格子。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .disabled(switching)
        .overlay {
            if switching {
                ProgressView()
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var characterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(app.characters, id: \.id) { candidate in
                    let chosen = candidate.id == characterID
                    Button {
                        characterID = candidate.id
                        switching = true
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
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
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

    private var weekBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { offset in
                    let chosen = weekOffset == offset
                    Button {
                        weekOffset = offset
                        switching = true
                    } label: {
                        Text(offset == 0 ? "本周" : "下周")
                            .font(.subheadline.weight(chosen ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background {
                                Capsule().fill(
                                    chosen ? Color.accentColor.opacity(0.2)
                                        : Color.secondary.opacity(0.1)
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
                Spacer()
                Text(range)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Text(character.map { ($0.nameZh ?? $0.name) + "的工作" } ?? "工作")
                    .font(.headline)
                Spacer()
            }
        }
    }

    private var range: String {
        let end = week.adding(days: 6)
        return "\(week.month)/\(week.day) – \(end.month)/\(end.day)"
    }

    private func weekGrid(_ planner: SchedulePlanner) -> some View {
        let today = ScheduleRules.localWeekday(now: Date(), timeZone: app.producerTimeZone)
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                Color.clear.frame(width: 26, height: 28)
                ForEach(0..<ScheduleRules.days, id: \.self) { day in
                    VStack(spacing: 0) {
                        Text(dayName(day))
                            .font(.caption2.weight(
                                day == today && weekOffset == 0 ? .bold : .regular
                            ))
                        Text(dateLabel(day))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                }
            }
            ForEach(0..<3, id: \.self) { slot in
                HStack(spacing: 4) {
                    Text(ScheduleSlot(rawValue: slot)?.name ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: cellHeight)
                    ForEach(0..<ScheduleRules.days, id: \.self) { day in
                        cellButton(planner.cell(day: day, slot: slot))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func dayName(_ day: Int) -> String {
        String(Array("一二三四五六日")[day])
    }

    private func dateLabel(_ day: Int) -> String {
        let date = week.adding(days: day)
        return "\(date.month)/\(date.day)"
    }

    private func cellButton(_ cell: ScheduleCell) -> some View {
        Button {
            tap(cell)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(cellColor(cell.state))
                cellLabel(cell)
            }
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
            .overlay {
                if cell.state.isDraft {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])
                        )
                } else if isAvailable(cell, planner: planner) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.2)
                } else if !cell.state.isSaved {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(cellBorderColor(cell.state), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility(cell))
        .accessibilityHint(accessibilityHint(cell))
    }

    private func cellLabel(_ cell: ScheduleCell) -> some View {
        Group {
            if let job = cell.state.job {
                Text(job.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(2)
            } else if case .now = cell.state {
                Text("现在")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    private func cellColor(_ state: ScheduleCellState) -> Color {
        switch state {
        case .saved: return Color.accentColor.opacity(0.85)
        case .draft: return Color.accentColor.opacity(0.35)
        case .now: return Color.orange.opacity(0.12)
        case .past: return Color.secondary.opacity(0.06)
        case .cannot: return Color.secondary.opacity(0.04)
        case .empty: return Color.secondary.opacity(0.06)
        }
    }

    private func cellBorderColor(_ state: ScheduleCellState) -> Color {
        switch state {
        case .empty: Color.secondary.opacity(0.28)
        case .now: Color.orange.opacity(0.45)
        case .past, .cannot: Color.secondary.opacity(0.12)
        case .saved, .draft: .clear
        }
    }

    private func isAvailable(_ cell: ScheduleCell, planner: SchedulePlanner?) -> Bool {
        guard let planner, let job = planner.selectedJob() else { return false }
        return planner.canPlace(job, day: cell.day, slot: cell.slot)
    }

    private func accessibility(_ cell: ScheduleCell) -> String {
        let slot = ScheduleSlot(rawValue: cell.slot)?.name ?? ""
        let day = week.adding(days: cell.day)
        let date = "\(day.month)月\(day.day)日周\(dayName(cell.day))，\(slot)"
        if let job = cell.state.job {
            return cell.state.isSaved ? "\(date)，已排\(job.name)" : "\(date)，草稿\(job.name)"
        }
        switch cell.state {
        case .now:
            return "\(date)，正在进行"
        case .past:
            return "\(date)，已经过了"
        case .cannot:
            return "\(date)，放不下"
        case .empty:
            return "\(date)，空闲"
        case .saved, .draft:
            return date
        }
    }

    private func accessibilityHint(_ cell: ScheduleCell) -> String {
        switch cell.state {
        case .empty:
            return "点一下把选中的工作排进来"
        case .draft:
            return "点一下把这项工作拿回草稿"
        case .saved:
            return "已经保存，不能再改"
        case .cannot:
            return "选中的工作放不下"
        case .past, .now:
            return "已经过去或正在进行"
        }
    }

    /// The pending count, the free cells left, and when the unsaved work expires (spec #59):
    /// a full week keeps its pending jobs, so the zero free cells explain why they stay.
    private func pendingSummary(_ planner: SchedulePlanner) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("待排 \(planner.pendingCount) 项")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("还能排 \(planner.freeCellCount) 格")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text(planner.pendingExpiresTonight ? "今晚 24 点后作废" : "周日 24 点后作废")
                    .font(.caption)
                    .foregroundStyle(planner.pendingExpiresTonight ? .primary : .secondary)
                    .accessibilityIdentifier("schedule.expiry")
                if planner.hasDrafts {
                    Text("\(planner.drafts.count) 项草稿未保存")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            if planner.pendingCount == 0 {
                Text("本周的工作都排好了")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if planner.selectedJobID != nil, planner.availableCells().isEmpty {
                Text("这周没有放得下的时间段")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("schedule.noRoom")
            }
        }
        .accessibilityIdentifier("schedule.pendingSummary")
    }

    private func cardList(_ planner: SchedulePlanner) -> some View {
        VStack(spacing: 8) {
            ForEach(planner.cards) { card in
                cardButton(card, planner: planner)
            }
        }
    }

    private func cardButton(_ card: ScheduleCard, planner: SchedulePlanner) -> some View {
        let selectable = isUnplaced(card.placement)
        let selected = planner.selectedJobID == card.job.id
        return Button {
            guard selectable else { return }
            var next = planner
            next.select(card.job.id)
            self.planner = next
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(card.job.name)
                            .font(.subheadline.weight(.semibold))
                        Text(status(card.placement))
                            .font(.caption2)
                            .foregroundStyle(statusColor(card.placement))
                    }
                    Text(card.job.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("\(slots(card.job)) · \(card.job.length) 段")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let reason = planner.reasons[card.job.id] {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
                if case .saved = card.placement {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .draft = card.placement {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(selectable ? 0.08 : 0.04))
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityIdentifier("schedule.card")
        .accessibilityLabel(
            "\(card.job.name)，\(status(card.placement))"
                + (planner.reasons[card.job.id].map { "，\($0)" } ?? "")
        )
        .accessibilityValue(selected ? "已选中" : "未选中")
        .accessibilityHint(selectable ? "选中后点一个空闲格子" : "已经排好")
    }

    private func isUnplaced(_ placement: ScheduleCard.Placement) -> Bool {
        if case .none = placement { return true }
        return false
    }

    private func status(_ placement: ScheduleCard.Placement) -> String {
        switch placement {
        case .none: return "待排"
        case .saved: return "已保存"
        case .draft: return "草稿"
        }
    }

    private func statusColor(_ placement: ScheduleCard.Placement) -> Color {
        switch placement {
        case .none: return .secondary
        case .saved: return .green
        case .draft: return .orange
        }
    }

    private func slots(_ job: WeeklyJob) -> String {
        if let slots = job.slots, !slots.isEmpty {
            return slots.map(\.name).joined(separator: "、")
        }
        return job.length == 3 ? "一整天" : "任意时段"
    }

    private func saveBar(_ planner: SchedulePlanner) -> some View {
        VStack(spacing: 4) {
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 6) {
                    if saving { ProgressView().tint(.white) }
                    Text(saving ? "保存中…" : "保存这一周（\(planner.drafts.count)）")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
            }
            .buttonStyle(.borderedProminent)
            .disabled(planner.drafts.isEmpty || saving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func emptyCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        }
    }

    // MARK: - Changing

    private func tap(_ cell: ScheduleCell) {
        guard var planner else { return }
        switch cell.state {
        case .saved:
            inspected = cell
            return
        case .past, .now:
            return
        case .cannot:
            notice = "这一格放不下选中的工作"
            return
        case .empty, .draft:
            break
        }
        guard planner.tap(day: cell.day, slot: cell.slot) else { return }
        notice = nil
        self.planner = planner
        commit(planner)
    }

    private func commit(_ planner: SchedulePlanner) {
        guard let key else { return }
        book.set(drafts: planner.drafts, reasons: planner.reasons, for: key)
    }

    private func save() async {
        guard var planner, let key else { return }
        saving = true
        notice = nil
        defer { saving = false }
        do {
            let result = try await app.core.saveSchedule(
                characterID: key.characterID, week: key.week,
                placements: planner.drafts, now: Date(), timeZone: app.producerTimeZone
            )
            planner.apply(result)
            book.set(drafts: planner.drafts, reasons: planner.reasons, for: key)
            self.planner = planner
            if result.refused.isEmpty {
                notice = "已保存 \(result.saved.count) 项。保存后不能再改。"
            } else {
                notice = "保存了 \(result.saved.count) 项，\(result.refused.count) 项没排成；原因在卡片上，换一个格子再试。"
            }
            await reloadBoard()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func inspectedAlert(_ cell: ScheduleCell) -> Alert {
        guard case let .saved(_, _, job) = cell.state else {
            return Alert(title: Text("已保存"))
        }
        return Alert(
            title: Text(job.name),
            message: Text("\(job.note)\n\n已经保存，不能再移动或删除。"),
            dismissButton: .default(Text("好"))
        )
    }
}

