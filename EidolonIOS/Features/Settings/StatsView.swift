import Charts
import EidolonCore
import SwiftUI

/// 设置 → 统计 (spec #96): how long the producer has known her, the days they came, the
/// year's heatmap, affinity, achievements, and the range's turns, calls, gifts and hours.
struct StatsView: View {
    @Environment(AppModel.self) private var app

    @State private var range: StatsRange = .all
    @State private var failed = false
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("区间", selection: $range) {
                    ForEach(StatsRange.allCases, id: \.self) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("stats.range")

                if loading, app.statsSummary == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if failed {
                    ContentUnavailableView {
                        Label("统计读不出来", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("再试一次。")
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                    .accessibilityIdentifier("stats.failed")
                } else if let summary = app.statsSummary {
                    if summary.hasContacts {
                        content(summary)
                    } else {
                        ContentUnavailableView {
                            Label("还没有往来", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("和她说过话、送过礼之后，这里会有统计。")
                        }
                        .accessibilityIdentifier("stats.empty")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("统计")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: range) { _, _ in Task { await load() } }
    }

    @ViewBuilder
    private func content(_ summary: StatsSummary) -> some View {
        portrait(summary)
        heatmap(summary.heatmap)
        affinity(summary.affinity)
        achievements(summary.achievements)
        rangeNumbers(summary.range)
        topCharacters(summary.range.characters)
        hours(summary.range.byHour)
        gifts(summary.range.gifts)
    }

    private func portrait(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("认识 \(summary.daysKnown) 天")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text("连续来访 \(summary.currentVisitStreak) 天 · 最长 \(summary.longestVisitStreak) 天")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("同一天说过话或送过礼算来过；今天还没来，从昨天往回数。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats.portrait")
    }

    private func heatmap(_ days: [StatsHeatmapDay]) -> some View {
        let busiest = days.map(\.count).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("过去一年")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(weeks(days).enumerated()), id: \.offset) { _, week in
                        VStack(spacing: 3) {
                            ForEach(week) { day in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(heatColor(day.count, busiest: busiest))
                                    .frame(width: 10, height: 10)
                                    .accessibilityLabel(
                                        "\(day.day.month)月\(day.day.day)日，\(day.count) 次"
                                    )
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Text("每周一列，颜色越深往来越多。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("过去一年的来访热力图")
        .accessibilityIdentifier("stats.heatmap")
    }

    private func affinity(_ groups: [StatsAffinityGroup]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("好感度")
                .font(.headline)
            ForEach(groups.filter { !$0.characterIDs.isEmpty }) { group in
                HStack(alignment: .firstTextBaseline) {
                    Text(group.tier.title)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 56, alignment: .leading)
                    Text(group.characterIDs.map(name).joined(separator: "、"))
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            Text("按当前档位，不按数值；冷却中的算冷淡。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("stats.affinity")
    }

    private func achievements(_ achievements: StatsAchievements) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trophy")
                .foregroundStyle(.orange)
            Text("成就已解锁 \(achievements.stages) 个阶段")
                .font(.subheadline)
                .monospacedDigit()
            Spacer(minLength: 0)
            Text("\(achievements.completedCharacters) 位集齐")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats.achievements")
    }

    private func rangeNumbers(_ range: StatsRangeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(range.range.title)
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                number("回合", "\(range.turns)")
                number("接通通话", "\(range.calls)")
                number("通话时长", duration(range.callSeconds))
                number("送出的礼物", "\(range.gifts.given)")
                number("她喜欢的", "\(range.gifts.liked)")
                if let most = range.gifts.mostCharacterID, range.gifts.mostGiven > 0 {
                    number("送得最多", "\(name(most)) \(range.gifts.mostGiven) 件")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("stats.rangeNumbers")
    }

    private func number(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        }
        .accessibilityElement(children: .combine)
    }

    private func topCharacters(_ characters: [StatsCharacterSummary]) -> some View {
        let talking = characters
            .filter { $0.turns > 0 }
            .sorted {
                $0.turns == $1.turns
                    ? order($0.characterID) < order($1.characterID)
                    : $0.turns > $1.turns
            }
            .prefix(5)
        let calling = characters
            .filter { $0.callSeconds > 0 }
            .sorted {
                $0.callSeconds == $1.callSeconds
                    ? order($0.characterID) < order($1.characterID)
                    : $0.callSeconds > $1.callSeconds
            }
            .prefix(5)
        return VStack(alignment: .leading, spacing: 12) {
            Text("花在谁身上")
                .font(.headline)
            if !talking.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("聊得最多")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(talking)) { character in
                        HStack {
                            Text(name(character.characterID))
                            Spacer(minLength: 0)
                            Text("认识 \(character.daysKnown) 天 · \(character.turns) 回合")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            }
            if !calling.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("通话最久")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(calling)) { character in
                        HStack {
                            Text(name(character.characterID))
                            Spacer(minLength: 0)
                            Text("认识 \(character.daysKnown) 天 · \(duration(character.callSeconds))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
            }
            if talking.isEmpty, calling.isEmpty {
                Text("这个区间还没有和她往来。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("stats.characters")
    }

    private func hours(_ counts: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("一天里的往来")
                .font(.headline)
            Chart(Array(counts.enumerated()), id: \.offset) { hour, count in
                BarMark(
                    x: .value("小时", hour),
                    y: .value("往来", count)
                )
                .foregroundStyle(Color.accentColor)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23])
            }
            .frame(height: 130)
            .accessibilityLabel("一天里的往来分布")
            .accessibilityValue(hoursSummary(counts))
            Text("按制作人档案的时区。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityIdentifier("stats.hours")
    }

    private func gifts(_ gifts: StatsGiftSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("礼物")
                .font(.headline)
            if gifts.kinds.isEmpty {
                Text("这个区间没有送过礼物。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(gifts.kinds.prefix(5)) { kind in
                    HStack {
                        Text(giftName(kind.giftID))
                        Spacer(minLength: 0)
                        Text("\(kind.given) 件 · 她喜欢 \(kind.liked)")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("stats.gifts")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        failed = !(await app.loadStats(range: range))
        if app.giftCatalog == nil { try? await app.refreshGifts() }
    }

    private func weeks(_ days: [StatsHeatmapDay]) -> [[StatsHeatmapDay]] {
        stride(from: 0, to: days.count, by: 7).map { start in
            Array(days[start..<min(start + 7, days.count)])
        }
    }

    /// Five shades by how busy the day was against the busiest day, as upstream's
    /// heatmap does: zero is blank, then four quarters of the busiest.
    private func heatColor(_ count: Int, busiest: Int) -> Color {
        guard count > 0, busiest > 0 else { return Color.secondary.opacity(0.08) }
        let share = Double(count) / Double(busiest)
        return switch share {
        case ..<0.25: Color.green.opacity(0.28)
        case ..<0.5: Color.green.opacity(0.45)
        case ..<0.75: Color.green.opacity(0.65)
        default: Color.green
        }
    }

    private func hoursSummary(_ counts: [Int]) -> String {
        let top = counts.enumerated()
            .filter { $0.element > 0 }
            .sorted { $0.element > $1.element }
            .prefix(3)
            .map { "\($0.offset) 时 \($0.element) 次" }
        return top.isEmpty ? "没有往来" : top.joined(separator: "，")
    }

    private func name(_ id: String) -> String {
        app.characters.first { $0.id == id }?.name ?? id
    }

    private func order(_ id: String) -> Int {
        app.characters.firstIndex { $0.id == id } ?? Int.max
    }

    private func giftName(_ id: String) -> String {
        app.giftCatalog?.gifts.first { $0.id == id }?.name ?? id
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3_600 {
            return "\(total / 3_600) 小时 \(total % 3_600 / 60) 分"
        }
        if total >= 60 {
            return "\(total / 60) 分 \(total % 60) 秒"
        }
        return "\(total) 秒"
    }
}
