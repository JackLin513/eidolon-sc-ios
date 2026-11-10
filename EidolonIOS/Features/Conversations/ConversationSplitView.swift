import EidolonCore
import SwiftUI

/// iPad regular-width conversations: the same roster `ConversationListView` draws, on the
/// left, and her chat on the right. The compact iPhone keeps that view's navigation stack;
/// this only changes the arrangement, not the pages or the row behaviour.
struct ConversationSplitView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedID: String?

    private var selected: CharacterConfig? {
        app.characters.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            ConversationListView(embedded: true) { character in
                selectedID = character.id
            }
            .navigationTitle("对话")
        } detail: {
            if let selected {
                NavigationStack {
                    ChatView(character: selected, hidesTabBar: false)
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
        .onAppear { adoptOpeningCharacter() }
        .onChange(of: app.conversationTargetID) { adoptOpeningCharacter() }
    }

    /// Another tab's 「去对话」 still goes through `AppModel`; the compact stack consumes
    /// it as a path, the split selects it here. Debug launches are consumed by the embedded
    /// roster itself and arrive through `onSelect`.
    private func adoptOpeningCharacter() {
        if let id = app.takeConversationTargetID() {
            selectedID = id
        }
    }
}
