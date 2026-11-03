import EidolonCore
import SwiftUI

/// A model list from a service, searchable, with the defaults and the current model marked
/// 推荐. Choosing one only fills the field; saving is still the page's own button.
struct ModelPickerRequest: Identifiable {
    let id = UUID()
    let title: String
    let models: [String]
    let current: String
    var allows: ((String) -> Bool)?
    let select: (String) -> Void

    init(
        title: String,
        models: [String],
        current: String,
        allows: ((String) -> Bool)? = nil,
        select: @escaping (String) -> Void
    ) {
        self.title = title
        self.models = models
        self.current = current
        self.allows = allows
        self.select = select
    }
}

struct ModelPickerView: View {
    let request: ModelPickerRequest
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var shown: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty
            ? request.models
            : request.models.filter { $0.lowercased().contains(query) }
        return filtered.sorted { left, right in
            let leftRecommended = isRecommended(left)
            let rightRecommended = isRecommended(right)
            if leftRecommended != rightRecommended { return leftRecommended }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private func isRecommended(_ model: String) -> Bool {
        ModelCatalog.recommended.contains(model) || model == request.current
    }

    private func isAllowed(_ model: String) -> Bool {
        request.allows?(model) ?? true
    }

    var body: some View {
        NavigationStack {
            List {
                if let allows = request.allows, !request.models.allSatisfy(allows) {
                    Section {
                        Text("内容包决定向量化模型，只有与它一致的项可以选。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(shown, id: \.self) { model in
                    Button {
                        request.select(model)
                        dismiss()
                    } label: {
                        HStack {
                            Text(model)
                                .foregroundStyle(isAllowed(model) ? .primary : .secondary)
                            Spacer()
                            if isRecommended(model) {
                                Text("推荐")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                            if model == request.current {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(!isAllowed(model))
                    .accessibilityIdentifier("api.model.\(model)")
                }
                if shown.isEmpty {
                    Text("没有匹配的模型")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $search, prompt: "搜索模型")
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
