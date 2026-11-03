import EidolonCore
import SwiftUI

/// What importing an upstream `.env` would do, before it does anything: the keys that
/// will be applied (secrets masked), the keys iOS does not read yet, the keys nobody
/// knows, malformed lines, invalid values and conflicts.
struct EnvImportPreviewView: View {
    let report: EnvImportReport
    let name: String
    let onImport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("来自 \(name)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("将改动", value: "\(report.mapped.count) 项")
                    if !report.invalid.isEmpty {
                        LabeledContent("无效值", value: "\(report.invalid.count) 项")
                    }
                    if !report.conflicts.isEmpty {
                        LabeledContent("冲突", value: "\(report.conflicts.count) 项")
                    }
                }

                if !report.mapped.isEmpty {
                    Section("将改动") {
                        ForEach(Array(report.mapped.enumerated()), id: \.offset) { _, entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label)
                                    Text(entry.key)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(entry.secret ? "将设置" : (value(for: entry.key) ?? "将更新"))
                                    .font(entry.secret ? .caption : .caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if !report.invalid.isEmpty {
                    Section("无效值（不会应用）") {
                        ForEach(Array(report.invalid.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.key)
                                    .font(.caption.monospaced())
                                Text("第 \(issue.line) 行：\(issue.message)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                if !report.conflicts.isEmpty {
                    Section("冲突（不应用或取最后一行）") {
                        ForEach(Array(report.conflicts.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.key)
                                    .font(.caption.monospaced())
                                Text("第 \(issue.line) 行：\(issue.message)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if !report.malformed.isEmpty {
                    Section("无法解析的行") {
                        ForEach(Array(report.malformed.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第 \(issue.line) 行")
                                    .font(.caption)
                                Text(issue.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !report.unsupported.isEmpty {
                    Section("暂不支持（不会导入）") {
                        ForEach(Array(report.unsupported.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.key)
                                    .font(.caption.monospaced())
                                Text(unsupportedNote(entry.key))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !report.unknown.isEmpty {
                    Section("未识别（不会导入）") {
                        ForEach(Array(report.unknown.enumerated()), id: \.offset) { _, entry in
                            Text(entry.key)
                                .font(.caption.monospaced())
                        }
                    }
                }

                if report.mapped.isEmpty {
                    Section {
                        Text("这个文件没有能应用的配置项。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("导入 .env")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入并保存") {
                        // The page closes this sheet itself, so the save that follows is
                        // shown on the page rather than behind a double dismissal.
                        onImport()
                    }
                    .fontWeight(.semibold)
                    .disabled(report.mapped.isEmpty)
                    .accessibilityIdentifier("api.import.confirm")
                }
            }
        }
    }

    /// A non-secret value, as the page will write it; secrets never reach the screen.
    private func value(for key: String) -> String? {
        let values = report.values
        switch key {
        case "CHAT_LLM_PROTOCOL": return values.chatProtocol?.rawValue
        case "CHAT_LLM_BASE_URL": return values.chatBaseURL
        case "CHAT_LLM_MODEL": return values.chatModel
        case "CHAT_LLM_MAX_TOKENS": return values.chatMaxTokens.map(String.init)
        case "CHAT_LLM_REASONING_EFFORT": return values.chatReasoningEffort?.rawValue
        case "CHAT_LLM_CALL_REASONING_EFFORT": return values.chatCallReasoningEffort?.rawValue
        case "CHAT_LLM_EXTRA_BODY": return Self.jsonText(values.chatExtraBody)
        case "BACKGROUND_LLM_PROTOCOL": return values.backgroundProtocol?.rawValue
        case "BACKGROUND_LLM_BASE_URL": return values.backgroundBaseURL
        case "BACKGROUND_LLM_MODEL": return values.backgroundModel
        case "BACKGROUND_LLM_MAX_TOKENS": return values.backgroundMaxTokens.map(String.init)
        case "BACKGROUND_LLM_REASONING_EFFORT":
            return values.backgroundReasoningEffort?.rawValue
        case "BACKGROUND_LLM_EXTRA_BODY": return Self.jsonText(values.backgroundExtraBody)
        case "JUDGE_PROVIDER": return values.judgeService?.rawValue
        case "JEV_MODEL": return values.jevModel
        case "JEV_BASE_URL": return values.jevBaseURL
        case "CLOUDFLARE_ACCOUNT_ID": return values.cloudflareAccountID
        case "CLOUDFLARE_JUDGE_MODEL": return values.cloudflareModel
        case "BAILIAN_JUDGE_WORKSPACE_ID": return values.bailianWorkspace
        case "BAILIAN_JUDGE_REGION": return values.bailianRegion?.rawValue
        case "BAILIAN_JUDGE_MODEL": return values.bailianModel
        case "JUDGE_EMOTION_MIN_PROBABILITY":
            return values.emotionMinProbability.map(Self.numberText)
        case "JUDGE_EMOTION_TIMEOUT": return values.emotionTimeout.map(Self.numberText)
        case "SILICONFLOW_BASE_URL": return values.siliconflowBaseURL
        case "EMBEDDING_MODEL": return values.embeddingModel
        case "EMBEDDING_DIMENSIONS": return values.embeddingDimensions.map(String.init)
        case "RERANK_MODEL": return values.rerankModel
        case "FISH_AUDIO_MODEL": return values.fishModel
        default: return nil
        }
    }

    private static func jsonText(_ value: [String: JSONValue]?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func numberText(_ value: Double) -> String {
        String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), arguments: [value])
    }

    private func unsupportedNote(_ key: String) -> String {
        if key.hasPrefix("GEMINI_") || key == "EMBEDDING_PROVIDER" {
            return "Gemini embedding 暂未接入（#89）"
        }
        if key.hasPrefix("DASHSCOPE_") || key.hasPrefix("BAILIAN_STT") || key == "STT_PROVIDER" {
            return "百炼实时识别暂未接入（#90）"
        }
        if key.hasPrefix("NOVELAI_") || key.hasPrefix("GPT_IMAGE_") {
            return "生图不在首版范围"
        }
        return "上游的部署或行为设置，iOS 的导入不读取"
    }
}
