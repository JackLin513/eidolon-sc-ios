import EidolonCore
import SwiftUI

/// What the idols remember about the producer: shared across them, with who was told.
/// A memory that was superseded is still listed, greyed out, but is never recalled.
struct MemoryListView: View {
    @Environment(AppModel.self) private var app

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
                }
            }
        }
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .task { await app.loadMemories() }
    }

    private static func day(_ stamp: String) -> String {
        guard let date = Eidolon.parseTimestamp(stamp) else { return stamp }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
