import EidolonCore
import SwiftUI
/// A section header that says whether its service is filled in, so the page reads at a
/// glance without opening every section.
struct APIStatusHeader: View {
    let title: String
    let configured: Bool
    var note: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: configured ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(configured ? Color.green : Color.secondary)
        }
    }
}

struct SummaryRow: View {
    let title: String
    let configured: Bool
    var note: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: configured ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(configured ? Color.green : Color.secondary)
            }
        } label: {
            Text(title)
        }
    }
}

enum ProbeStatus {
    case running
    case success(ProbeResult)
    case failure(ProbeResult)
}

struct ProbeStatusRow: View {
    let result: ProbeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.ok ? Color.green : Color.red)
                Text(result.ok ? "成功" : "失败")
                    .font(.footnote.weight(.semibold))
                Text("\(result.milliseconds) ms")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let status = result.statusCode {
                    Text("HTTP \(status)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !result.detail.isEmpty {
                Text(result.detail)
                    .font(.caption)
                    .foregroundStyle(result.ok ? Color.secondary : Color.red)
            }
            if let model = result.model, !model.isEmpty {
                Text("模型：\(model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("api.probe.result")
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
