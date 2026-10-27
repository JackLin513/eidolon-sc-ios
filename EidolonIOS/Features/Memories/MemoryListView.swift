import EidolonCore
import SwiftUI

/// What the idols remember about the producer: shared across them, with who was told.
/// A memory that was superseded is still listed, greyed out, but is never recalled.
/// Memories can be forgotten one at a time, or all at once (upstream `Memory.delete`,
/// `Memory.clear`).
struct MemoryListView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingClear = false
    @State private var error: String?

    private var names: [String: String] {
        Dictionary(uniqueKeysWithValues: app.characters.map { ($0.id, $0.name) })
    }

    var body: some View {
        List {
            if app.memories.isEmpty {
                ContentUnavailableView(
                    "还没有记忆",
                    systemImage: "brain",
                    description: Text("聊天时制作人提到的、值得记住的事会出现在这里。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(app.memories.reversed(), id: \.id) { memory in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(memory.text)
                            .foregroundStyle(memory.holds ? .primary : .secondary)
                        HStack(spacing: 6) {
                            if let source = memory.sourceCharacterID {
                                Text(names[source] ?? source)
                            }
                            Text(Self.day(memory.createdAt))
                            if !memory.holds {
                                Text("已被取代")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await delete(memory) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !app.memories.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .confirmationDialog(
            "清空所有记忆？",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                Task { await clear() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("她们会忘掉你告诉过她们的所有事。")
        }
        .alert("出错了", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .task { await app.loadMemories() }
    }

    private func delete(_ memory: MemoryRecord) async {
        do {
            try await app.deleteMemory(id: memory.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clear() async {
        do {
            try await app.clearMemories()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func day(_ stamp: String) -> String {
        guard let date = Eidolon.parseTimestamp(stamp) else { return stamp }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
