import EidolonCore
import SwiftUI

/// Her conversations, newest first: the current one and the past ones. Past conversations
/// can be opened to read and deleted for good; a conversation below the current one can
/// never be typed in again.
struct ConversationHistoryView: View {
    let character: CharacterConfig

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [ConversationSummary] = []
    @State private var error: String?

    var body: some View {
        List {
            if conversations.isEmpty {
                ContentUnavailableView(
                    "还没有对话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("和她说句话，这里就会有记录。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(conversations) { conversation in
                    NavigationLink {
                        ChatView(character: character, conversationID: conversation.id)
                    } label: {
                        row(conversation)
                    }
                    .swipeActions(edge: .trailing) {
                        if !conversation.isCurrent {
                            Button(role: .destructive) {
                                Task { await delete(conversation) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("对话记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .task { await load() }
        .alert("出错了", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func row(_ conversation: ConversationSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(conversation.title ?? "未命名对话")
                    .font(.headline)
                    .foregroundStyle(conversation.isCurrent ? .primary : .secondary)
                if conversation.isCurrent {
                    Text("当前")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                if conversation.ended {
                    Text("已结束")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(conversation.lastPreview ?? "（还没有说话）")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Self.day(conversation.lastAt ?? conversation.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do {
            conversations = try await app.core.conversations(characterID: character.id)
            await app.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ conversation: ConversationSummary) async {
        do {
            try await app.core.deleteConversation(id: conversation.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func day(_ stamp: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: stamp) else { return stamp }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
