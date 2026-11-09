import EidolonCore
import SwiftUI

/// iPad regular-width conversations: the roster on the left, her chat on the right. The
/// compact iPhone keeps `ConversationListView`'s single navigation stack; this view only
/// changes the arrangement, not the pages.
struct ConversationSplitView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var selectedID: String?

    private var filtered: [CharacterConfig] {
        let ordered = ConversationOrder.byRecency(app.characters, latest: app.latest)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ordered }
        return ordered.filter { $0.matches(needle) }
    }

    private var selected: CharacterConfig? {
        app.characters.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(filtered, id: \.id) { character in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(character.name)
                            .font(.headline)
                        if !character.subtitle.isEmpty {
                            Text(character.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(
                            app.latest[character.id]?.lastMessagePreview
                                ?? character.intro
                                ?? "还没聊过"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .tag(character.id)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, prompt: "搜中文名、假名、罗马字或组合")
            .navigationTitle("对话")
            .overlay {
                if app.characters.isEmpty {
                    ContentUnavailableView(
                        "没有角色",
                        systemImage: "person.2",
                        description: Text("这份内容包里没有角色")
                    )
                }
            }
        } detail: {
            if let selected {
                NavigationStack {
                    ChatView(character: selected)
                }
            } else {
                ContentUnavailableView(
                    "选一个角色",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("从左边选一位开始聊天")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
