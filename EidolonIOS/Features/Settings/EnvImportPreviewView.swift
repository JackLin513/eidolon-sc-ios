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
                                Text(entry.secret ? "将设置" : "将更新")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
