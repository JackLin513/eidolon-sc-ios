import Charts
import EidolonCore
import SwiftUI

/// 设置 → 用量与花费 (spec #96): what each outside service used in a range, priced from the
/// built-in catalog (or the producer's own prices), by currency, as an estimate.
struct UsageView: View {
    @Environment(AppModel.self) private var app

    @State private var range: UsageRange = .thirtyDays
    @State private var metric: UsageMetric = .cost
    @State private var failed = false
    @State private var loading = true
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("区间", selection: $range) {
                    ForEach(UsageRange.allCases, id: \.self) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("usage.range")

                if loading, app.usageStats == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if failed {
                    ContentUnavailableView {
                        Label("用量读不出来", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("再试一次。")
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                    .accessibilityIdentifier("usage.failed")
                } else if let stats = app.usageStats {
                    if stats.hasAny {
                        content(stats)
                    } else {
                        ContentUnavailableView {
                            Label(
                                stats.hasRecords ? "这个区间没有用量" : "从这次更新开始统计",
                                systemImage: "chart.bar"
                            )
                        } description: {
                            Text(
                                stats.hasRecords
                                    ? "换一个区间看看。"
                                    : "这里会记录每次对话、判断、向量、语音合成和识别用了多少，并按价格表估算花费。"
                            )
                        }
                        .accessibilityIdentifier("usage.empty")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    pricesLink
                    clearButton(stats)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("用量与花费")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: range) { _, _ in Task { await load() } }
        .alert("清空用量记录？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) {
                Task {
                    await app.clearUsage()
                    await load()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除本机所有服务调用记录；价格设置保留。这个操作不能撤销。")
        }
    }

    @ViewBuilder
    private func content(_ stats: UsageStats) -> some View {
        totals(stats)
        daily(stats.days)
        services(stats.services)
        Text("价格表：内置 PRESETS（\(stats.pricesAsOf)）加上 DeepSeek 与 Gemini 的公开价（Gemini 2026-11-04），可在「单价与币种」改；本地模型按 0 元。百炼 3.1 按官方音频 token 价折成秒估算。估算不是账单：服务商没报用量时按文本长度估算，免费额度和汇率都没有算。")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("usage.note")
    }

    private func totals(_ stats: UsageStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("你的估算花费")
                .font(.headline)
            if stats.amounts.isEmpty {
                Text(stats.unpricedCalls > 0 ? "未设单价" : "0")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    ForEach(Array(stats.amounts.enumerated()), id: \.offset) { _, money in
                        Text(moneyText(money))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
            HStack(spacing: 12) {
                Text("\(stats.calls) 次调用")
                    .monospacedDigit()
                if stats.estimatedCalls > 0 {
                    Text("\(stats.estimatedCalls) 次估算")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if stats.unpricedCalls > 0 {
                    Text("\(stats.unpricedCalls) 次未设单价")
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage.totals")
    }

    private func daily(_ days: [UsageDay]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("每天的趋势")
                    .font(.headline)
                Spacer(minLength: 0)
                Picker("趋势", selection: $metric) {
                    ForEach(UsageMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
                .accessibilityIdentifier("usage.metric")
            }
            Chart {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    if metric == .calls {
                        BarMark(
                            x: .value("日期", index),
                            y: .value("调用", day.calls)
                        )
                        .foregroundStyle(Color.accentColor)
                    } else {
                        ForEach(Array(day.amounts.enumerated()), id: \.offset) { _, money in
                            BarMark(
                                x: .value("日期", index),
                                y: .value("花费", NSDecimalNumber(decimal: money.amount).doubleValue)
                            )
                            .foregroundStyle(by: .value("币种", money.currency))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let index = value.as(Int.self), days.indices.contains(index) {
                            Text(shortDay(days[index].day))
                        }
                    }
                }
            }
            .frame(height: 120)
            .accessibilityLabel(metric == .calls ? "每天的调用次数" : "每天的估算花费")
            .accessibilityValue(dailySummary(days))
            if metric == .cost, days.allSatisfy({ $0.amounts.isEmpty }) {
                Text("这些调用还没有单价，先看调用次数，或在下面设单价。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("usage.daily")
    }

    private func dailySummary(_ days: [UsageDay]) -> String {
        if metric == .calls {
            return days.filter { $0.calls > 0 }.suffix(5)
                .map { "\(shortDay($0.day)) \($0.calls) 次" }
                .joined(separator: "，")
        }
        return days.filter { !$0.amounts.isEmpty }.suffix(5)
            .map { day in
                "\(shortDay(day.day)) " + day.amounts.map(moneyText).joined(separator: " + ")
            }
            .joined(separator: "，")
    }

    private func services(_ services: [UsageServiceSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按服务")
                .font(.headline)
            ForEach(services) { service in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(service.models) { model in
                            modelRow(model)
                            if model.id != service.models.last?.id { Divider() }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(service.service.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 0)
                            Text("\(service.calls) 次")
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(serviceSummary(service))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("usage.service.\(service.service.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("usage.services")
    }

    private func serviceSummary(_ service: UsageServiceSummary) -> String {
        var parts: [String] = []
        var byUnit: [ServiceUnit: Int] = [:]
        for model in service.models {
            byUnit[model.unit, default: 0] += model.input
        }
        for unit in ServiceUnit.allCases {
            guard let input = byUnit[unit], input > 0 else { continue }
            parts.append("\(number(input)) \(unit.title)")
        }
        if !service.amounts.isEmpty {
            parts.append(service.amounts.map(moneyText).joined(separator: " + "))
        } else if service.unpricedCalls > 0 {
            parts.append("未设单价")
        }
        return parts.isEmpty ? "没有用量" : parts.joined(separator: " · ")
    }

    private func modelRow(_ model: UsageModelSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.model.isEmpty ? "未知模型" : model.model)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let price = model.price {
                    Text(model.amounts.isEmpty ? "0" : model.amounts.map(moneyText).joined(separator: " + "))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                } else {
                    Text("未设单价")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 8) {
                Text(model.provider.isEmpty ? "没有记录提供方" : model.provider)
                Text("·")
                Text(usageText(model))
                    .monospacedDigit()
                if model.estimatedCalls > 0 {
                    Text("估算 \(model.estimatedCalls)")
                        .foregroundStyle(.secondary)
                }
                if model.price?.source == .local {
                    Text("本地")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.cachedInput > 0 {
                Text("其中缓存输入 \(number(model.cachedInput)) \(model.unit.title)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var pricesLink: some View {
        NavigationLink {
            PriceEditorView()
        } label: {
            LabeledContent("单价与币种", value: "⇢")
        }
        .accessibilityIdentifier("usage.prices")
    }

    private func clearButton(_ stats: UsageStats) -> some View {
        Button("清空用量记录", role: .destructive) {
            confirmingClear = true
        }
        .disabled(!stats.hasRecords)
        .accessibilityIdentifier("usage.clear")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        failed = !(await app.loadUsage(range: range))
    }

    private func usageText(_ model: UsageModelSummary) -> String {
        switch model.unit {
        case .tokens:
            if model.output > 0 {
                return "\(number(model.input)) 入 / \(number(model.output)) 出"
            }
            return "\(number(model.input)) tokens"
        case .seconds:
            return "\(number(model.input)) 秒"
        case .images:
            return "\(number(model.input)) 张"
        case .bytes, .characters:
            return "\(number(model.input)) \(model.unit.title)"
        }
    }

    private func moneyText(_ money: UsageMoney) -> String {
        let symbol: String
        switch money.currency {
        case "CNY": symbol = "¥"
        case "USD": symbol = "$"
        default: symbol = money.currency + " "
        }
        let amount = money.amount.formatted(.number.precision(.fractionLength(0...4)))
        return symbol + amount
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func shortDay(_ day: CalendarDay) -> String {
        "\(day.month)/\(day.day)"
    }
}

private enum UsageMetric: String, CaseIterable, Identifiable {
    case calls
    case cost

    var id: String { rawValue }
    var title: String { self == .calls ? "调用次数" : "估算花费" }
}
