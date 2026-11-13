import EidolonCore
import SwiftUI
import UIKit

/// The debug-only sheet behind a reply's 「调试上下文」 button. It shows what this one
/// turn actually read and how it was judged; it is not a general trace browser.
struct DebugTurnContextView: View {
    let record: TurnDebugSnapshotRecord

    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    private var snapshot: TurnDebugSnapshot { record.snapshot }

    var body: some View {
        NavigationStack {
            List {
                overview
                judgeSection
                retrievalSection
                contextSection
                requestsSection
                rawSection
            }
            .navigationTitle("调试上下文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        copy(prettyJSON, label: "完整 JSON")
                    } label: {
                        Image(systemName: copied == "完整 JSON" ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel("复制完整调试 JSON")
                }
            }
        }
    }

    // MARK: - Overview

    private var overview: some View {
        Section("概览") {
            LabeledContent("状态") {
                Text(snapshot.status.title)
                    .foregroundStyle(statusColor)
            }
            if let error = snapshot.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            LabeledContent("时间", value: snapshot.createdAt)
            if let conversation = snapshot.conversationID {
                LabeledContent("对话", value: String(conversation.prefix(8)))
            }
            if let model = snapshot.model, !model.isEmpty {
                LabeledContent("模型", value: model)
            }
            if let host = snapshot.providerHost, !host.isEmpty {
                LabeledContent("服务", value: host)
            }
            if let talking = snapshot.talking {
                LabeledContent("场景", value: talking)
            }
            if let style = snapshot.replyStyle {
                LabeledContent("回复形态", value: style)
            }
            if let adult = snapshot.adultMode {
                LabeledContent("成人模式", value: adult ? "开" : "关")
            }
            if let input = snapshot.inputTokens {
                LabeledContent("输入 token", value: "\(input)")
            }
            if let output = snapshot.outputTokens {
                LabeledContent("输出 token", value: "\(output)")
            }
            if let cached = snapshot.cachedInputTokens {
                LabeledContent("缓存输入", value: "\(cached)")
            }
            if let timings = snapshot.timings {
                if let total = timings.total {
                    LabeledContent("总耗时", value: seconds(total))
                }
                if let firstToken = timings.firstToken {
                    LabeledContent("首字延迟", value: seconds(firstToken))
                }
                if let retrieval = timings.retrieval {
                    LabeledContent("检索", value: seconds(retrieval))
                }
                if let memory = timings.memory {
                    LabeledContent("等待记忆", value: seconds(memory))
                }
            }
            if !snapshot.requests.isEmpty {
                LabeledContent("请求轮次", value: "\(snapshot.requests.count)")
            }
            if !snapshot.toolCalls.isEmpty {
                LabeledContent("工具调用", value: "\(snapshot.toolCalls.count)")
            }
        }
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .complete: .green
        case .failed: .orange
        case .cancelled: .secondary
        }
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }

    // MARK: - Judge

    private var judgeSection: some View {
        Section {
            if let judge = snapshot.judge {
                LabeledContent("服务", value: judge.service)
                LabeledContent("模型", value: judge.model)
                if let family = judge.family { LabeledContent("模型族", value: family) }
                if let input = judge.inputTokens { LabeledContent("输入 token", value: "\(input)") }
                if let latency = judge.latency { LabeledContent("耗时", value: seconds(latency)) }
                if let failure = judge.failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let verdict = snapshot.verdict {
                    Text(verdict)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                if let raw = judge.raw, !raw.isEmpty {
                    DisclosureGroup("原始响应") {
                        Text(raw)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("本轮没有运行判断模型。")
                    .foregroundStyle(.secondary)
            }
            Text("文本聊天不运行七表情判断；七表情只在通话片段中运行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("判断模型")
        }
    }

    // MARK: - Retrieval

    private var retrievalSection: some View {
        Section("检索") {
            if let retrieval = snapshot.retrieval {
                if !retrieval.need.isEmpty {
                    LabeledContent("需要", value: retrieval.need)
                }
                if let query = retrieval.query, !query.isEmpty {
                    Text(query)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                ForEach(Array(retrieval.candidates.enumerated()), id: \.offset) { _, candidate in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(candidate.chosen ? "✓" : "·")
                                .foregroundStyle(candidate.chosen ? .green : .secondary)
                            Text(candidate.kind)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.3f", candidate.similarity))
                                .font(.caption.monospaced())
                            if let score = candidate.score {
                                Text(String(format: "rerank %.3f", score))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(candidate.title)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                if !retrieval.degradation.isEmpty {
                    ForEach(retrieval.degradation, id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.orange)
                    }
                }
            } else {
                Text("本轮没有检索结果。").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Context sections

    private var contextSection: some View {
        Section("实际读取的上下文") {
            if snapshot.sections.isEmpty {
                Text("没有捕获到上下文字符串。").foregroundStyle(.secondary)
            }
            ForEach(snapshot.sections) { section in
                DisclosureGroup {
                    Text(section.content)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                            Text(section.kind)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            copy(section.content, label: section.title)
                        } label: {
                            Image(systemName: copied == section.title ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("复制\(section.title)")
                    }
                }
            }
        }
    }

    // MARK: - Requests

    private var requestsSection: some View {
        Section("实际请求") {
            if snapshot.requests.isEmpty {
                Text("本轮没有捕获到请求。").foregroundStyle(.secondary)
            }
            ForEach(snapshot.requests) { request in
                DisclosureGroup("第 \(request.index) 轮 · \(request.messages.count) 条消息") {
                    ForEach(Array(request.messages.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message.content)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let calls = message.toolCalls, !calls.isEmpty {
                                Text(calls.joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if let raw = request.rawResponse, !raw.isEmpty {
                        DisclosureGroup("模型原始输出") {
                            Text(raw)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Raw JSON

    private var rawSection: some View {
        Section {
            DisclosureGroup("原始调试 JSON") {
                Text(prettyJSON)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func copy(_ string: String, label: String) {
        UIPasteboard.general.string = string
        copied = label
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copied == label { copied = nil }
        }
    }
}
