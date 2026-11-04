import EidolonCore
import SwiftUI

/// 用量与花费 → 单价与币种 (spec #96): the built-in prices, the producer's overrides, and
/// the models the ledger has seen that have no price yet.
struct PriceEditorView: View {
    @Environment(AppModel.self) private var app

    @State private var editing: PriceEditorRow?
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        List {
            if app.priceRows.isEmpty {
                if loading {
                    ProgressView()
                } else if failed {
                    ContentUnavailableView(
                        "价格读不出来", systemImage: "exclamationmark.triangle",
                        description: Text("再试一次。")
                    )
                } else {
                    ContentUnavailableView(
                        "还没有价格", systemImage: "tag",
                        description: Text("用过外部服务之后，这里会列出它的单价。")
                    )
                }
            } else {
                ForEach(providers, id: \.self) { provider in
                    Section(provider) {
                        ForEach(rows(for: provider)) { row in
                            Button {
                                editing = row
                            } label: {
                                rowLabel(row)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("price.row.\(row.id)")
                        }
                    }
                }
            }
        }
        .navigationTitle("单价与币种")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $editing) { row in
            PriceEditSheet(row: row)
        }
    }

    private func rowLabel(_ row: PriceEditorRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.key.model)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(row.key.unit.title)
                    switch row.source {
                    case .override: Text("已改").foregroundStyle(.blue)
                    case .preset: Text("内置").foregroundStyle(.secondary)
                    case .local: Text("本地").foregroundStyle(.secondary)
                    case nil: Text("未设单价").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
            if let rate = row.rate {
                Text(priceText(rate, unit: row.key.unit))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var providers: [String] {
        Array(Set(app.priceRows.map(\.key.provider))).sorted()
    }

    private func rows(for provider: String) -> [PriceEditorRow] {
        app.priceRows.filter { $0.key.provider == provider }
    }

    private func priceText(_ rate: PriceRate, unit: ServiceUnit) -> String {
        let symbol: String
        switch rate.currency {
        case "CNY": symbol = "¥"
        case "USD": symbol = "$"
        default: symbol = rate.currency + " "
        }
        let input = rate.input.formatted(.number.precision(.fractionLength(0...4)))
        if let output = rate.output {
            let out = output.formatted(.number.precision(.fractionLength(0...4)))
            return "\(symbol)\(input) / \(out)"
        }
        return "\(symbol)\(input)"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        failed = !(await app.loadPriceRows())
    }
}

private struct PriceEditSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let row: PriceEditorRow

    @State private var input = ""
    @State private var output = ""
    @State private var cachedInput = ""
    @State private var currency = "CNY"
    @State private var error: String?
    @State private var saving = false

    init(row: PriceEditorRow) {
        self.row = row
        _input = State(initialValue: row.rate.map {
            NSDecimalNumber(decimal: $0.input).stringValue
        } ?? "")
        _output = State(initialValue: row.rate?.output.map {
            NSDecimalNumber(decimal: $0).stringValue
        } ?? "")
        _cachedInput = State(initialValue: row.rate?.cachedInput.map {
            NSDecimalNumber(decimal: $0).stringValue
        } ?? "")
        _currency = State(initialValue: row.rate?.currency ?? "CNY")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(row.key.model)
                        .font(.subheadline)
                    Text("\(row.key.provider) · \(row.key.unit.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(unitNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("单价") {
                    field("输入", text: $input)
                    field("输出（留空与输入同价）", text: $output)
                    field("缓存输入（留空与输入同价）", text: $cachedInput)
                    Picker("币种", selection: $currency) {
                        Text("人民币 CNY").tag("CNY")
                        Text("美元 USD").tag("USD")
                    }
                }

                if row.source == .override {
                    Section {
                        Button("恢复内置价格", role: .destructive) {
                            Task { await restore() }
                        }
                        .accessibilityIdentifier("price.restore")
                    }
                }

                Section {
                    Text("改价只影响这台手机上的估算，不会改动服务商的账单；历史用量按新单价重算。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("单价")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(saving || parsedInput == nil)
                        .accessibilityIdentifier("price.save")
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("好") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.decimalPad)
            .monospacedDigit()
    }

    private var unitNote: String {
        switch row.key.unit {
        case .tokens, .bytes, .characters: "每百万 \(row.key.unit.title) 的价格。"
        case .seconds: "每小时音频的价格。"
        case .images: "每张图的价格。"
        }
    }

    private var parsedInput: Decimal? { parse(input) }
    private var parsedOutput: Decimal? { parse(output) }
    private var parsedCached: Decimal? { parse(cachedInput) }

    private func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func save() async {
        guard let input = parsedInput else { return }
        if !output.trimmingCharacters(in: .whitespaces).isEmpty, parsedOutput == nil {
            error = "输出单价不是数字。"
            return
        }
        if !cachedInput.trimmingCharacters(in: .whitespaces).isEmpty, parsedCached == nil {
            error = "缓存输入单价不是数字。"
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await app.savePrice(
                row.key, input: input,
                output: output.trimmingCharacters(in: .whitespaces).isEmpty ? nil : parsedOutput,
                cachedInput: cachedInput.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : parsedCached,
                currency: currency
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore() async {
        saving = true
        defer { saving = false }
        do {
            try await app.restorePrice(row.key)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
