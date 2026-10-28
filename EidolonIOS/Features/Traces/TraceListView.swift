import EidolonCore
import SwiftUI

/// Every kept turn's trace, newest first: to see what she was asked and where a turn went
/// wrong. They stay in the user library; exporting writes them to a file the producer shares.
struct TraceListView: View {
    @Environment(AppModel.self) private var app
    @State private var traces: [TurnTraceRecord] = []
    @State private var exportURL: URL?
    @State private var confirmingClear = false
    @State private var selected: TurnTraceRecord?
    @State private var error: String?

    private func name(of characterID: String) -> String {
        app.characters.first { $0.id == characterID }?.name ?? characterID
    }

    var body: some View {
        List {
            if traces.isEmpty {
                ContentUnavailableView(
                    "还没有追踪",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("回合结束或失败时会在这里留下记录。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(traces) { record in
                    Button {
                        selected = record
                    } label: {
                        row(record)
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle("回合追踪")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(traces.isEmpty)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selected != nil },
            set: { if !$0 { selected = nil } }
        )) {
            if let selected {
                TraceDetailView(
                    record: selected,
                    characterName: name(of: selected.trace.characterID)
                )
            }
        }
        .task {
            await load()
            #if DEBUG
            if app.debugShowsLatestTrace, selected == nil {
                selected = traces.first
            }
            #endif
        }
        .confirmationDialog("清空全部追踪？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) {
                Task { await clear() }
            }
        }
        .alert("出错了", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func row(_ record: TurnTraceRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(name(of: record.trace.characterID))
                    .font(.headline)
                Text(Self.stamp(record.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if record.trace.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let error = record.trace.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if !record.trace.degradation.isEmpty {
                Text(record.trace.degradation.joined(separator: "；"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("检索：\(record.trace.retrieval.need)，候选 \(record.trace.retrieval.candidates.count) 条\(totalSuffix(record))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// The whole turn, when it was recorded: what a slow reply feels like, at a glance.
    private func totalSuffix(_ record: TurnTraceRecord) -> String {
        guard let total = record.trace.timings?.total else { return "" }
        return " · 总耗时 \(Self.seconds(total))"
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.2f 秒", value)
    }

    private func load() async {
        do {
            traces = try await app.core.turnTraces(limit: app.chatSettings.traceRetention)
            let data = try await app.core.exportedTraces()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("eidolon-traces.json")
            try data.write(to: url)
            exportURL = url
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clear() async {
        do {
            try await app.core.clearTraces()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func stamp(_ iso: String) -> String {
        guard let date = Eidolon.parseTimestamp(iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

struct TraceDetailView: View {
    let record: TurnTraceRecord
    let characterName: String

    private var trace: TurnTrace { record.trace }

    var body: some View {
        List {
            Section("概览") {
                LabeledContent("角色", value: characterName)
                if let conversation = record.conversationID {
                    LabeledContent("对话", value: String(conversation.prefix(8)))
                }
                LabeledContent("时间", value: record.createdAt)
                if let error = trace.error {
                    Text(error)
                        .foregroundStyle(.orange)
                }
                if let verdict = trace.verdict {
                    LabeledContent("判断", value: verdict)
                }
            }

            if !trace.degradation.isEmpty {
                Section("降级原因") {
                    ForEach(Array(trace.degradation.enumerated()), id: \.offset) { _, reason in
                        Text(reason)
                            .font(.callout)
                    }
                }
            }

            if let timings = trace.timings {
                Section("耗时") {
                    if let memory = timings.memory {
                        LabeledContent("等待记忆", value: Self.seconds(memory))
                    }
                    if let judge = trace.judge?.latency {
                        LabeledContent("判断", value: Self.seconds(judge))
                    }
                    if let retrieval = timings.retrieval {
                        LabeledContent("检索", value: Self.seconds(retrieval))
                    }
                    if let firstToken = timings.firstToken {
                        LabeledContent("首 token", value: Self.seconds(firstToken))
                    }
                    if let total = timings.total {
                        LabeledContent("总耗时", value: Self.seconds(total))
                    }
                }
            }

            Section("判断") {
                if let judge = trace.judge {
                    LabeledContent("服务", value: judge.service)
                    if !judge.model.isEmpty {
                        LabeledContent("模型", value: judge.model)
                    }
                    if let family = judge.family {
                        LabeledContent("族", value: family)
                    }
                    if judge.uncalibrated == true {
                        Text(JudgeCalibration.uncalibratedNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let tokens = judge.inputTokens {
                        LabeledContent("输入 token", value: "\(tokens)")
                    }
                    if let latency = judge.latency {
                        LabeledContent("耗时", value: Self.seconds(latency))
                    }
                    if let failure = judge.failure {
                        Text(failure)
                            .foregroundStyle(.orange)
                    }
                    if let raw = judge.raw {
                        Text(raw)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } else {
                    Text("没有（未配置判断模型）")
                        .foregroundStyle(.secondary)
                }
            }

            Section("检索") {
                LabeledContent("需要", value: trace.retrieval.need)
                if let query = trace.retrieval.query {
                    Text(query)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(Array(trace.retrieval.candidates.enumerated()), id: \.offset) { _, candidate in
                    candidateRow(candidate)
                }
            }

            Section("工具调用") {
                if trace.toolCalls.isEmpty {
                    Text("没有")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(trace.toolCalls.enumerated()), id: \.offset) { _, call in
                    Text(call)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            ForEach(Array(trace.prompts.enumerated()), id: \.offset) { index, messages in
                Section("完整提示词（第 \(index + 1) 次请求，\(messages.count) 条消息）") {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role + (message.toolCalls.map { " · \($0.joined(separator: " "))" } ?? ""))
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Text(message.content)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("回合追踪")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.2f 秒", value)
    }

    private func candidateRow(_ candidate: RetrievalCandidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: candidate.chosen ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(candidate.chosen ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.callout)
                    .lineLimit(2)
                Text(
                    "\(candidate.kind) · 相似度 \(String(format: "%.3f", candidate.similarity))"
                        + (candidate.score.map { " · 重排 \(String(format: "%.3f", $0))" } ?? "")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}
