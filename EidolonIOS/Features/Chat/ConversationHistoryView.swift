import EidolonCore
import SwiftUI

/// Her conversations, newest first: the current one and the past ones. Past conversations
/// can be opened to read and deleted for good; a conversation below the current one can
/// never be typed in again.
struct ConversationHistoryView: View {
    let character: CharacterConfig
    /// Whether the page that opened the history is still waiting on a reply (spec #37).
    var currentTurnInFlight: Bool = false

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [ConversationSummary] = []
    @State private var error: String?
    /// The conversation a swipe asked to delete; nil while nobody has asked (spec #35).
    @State private var pendingDelete: ConversationSummary?

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
                        ChatView(
                            character: character,
                            conversationID: conversation.id,
                            currentTurnInFlight: currentTurnInFlight
                        )
                    } label: {
                        row(conversation)
                    }
                    .swipeActions(edge: .trailing) {
                        if !conversation.isCurrent {
                            Button(role: .destructive) {
                                // The swipe only says which one; the delete waits for a
                                // second, deliberate tap.
                                pendingDelete = conversation
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    // Debug mode's shortcut (spec #62): a past conversation can be put
                    // back in use without opening it and going through the debug sheet.
                    // The swipe is the deliberate act; the history closes when the
                    // revision changes and the base page shows the new current.
                    .swipeActions(edge: .leading) {
                        if app.debugMode, !conversation.isCurrent,
                           !currentTurnInFlight, !app.call.isLive {
                            Button {
                                Task { await restore(conversation) }
                            } label: {
                                Label(
                                    conversation.ended ? "恢复为当前" : "设为当前",
                                    systemImage: conversation.ended
                                        ? "arrow.uturn.backward" : "pin"
                                )
                            }
                            .tint(.accentColor)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            CallBar()
        }
        .navigationTitle("对话记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .task { await load() }
        // A new conversation started from one of the past ones closes the history: the
        // page underneath is already showing it (spec #37).
        .onChange(of: app.conversationRevision) {
            dismiss()
        }
        // Returning to the call brings the layer over every page; the history gets out of
        // its way (spec #46).
        .onChange(of: app.call.layer) { _, layer in
            if layer == .expanded { dismiss() }
        }
        .confirmationDialog(
            "删除这段对话？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { conversation in
            Button("删除", role: .destructive) {
                pendingDelete = nil
                Task { await delete(conversation) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("删除后无法恢复。")
        }
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

    /// The debug shortcut: the swiped conversation becomes the current one, and an
    /// ended one is opened again in the same move. The old current falls into history
    /// untouched; the revision change closes this sheet and the page below reloads.
    private func restore(_ conversation: ConversationSummary) async {
        do {
            let moved = try await app.setDebugCurrentConversation(
                characterID: character.id,
                id: conversation.id,
                reopen: conversation.ended
            )
            guard moved else {
                error = "这段对话不属于这位角色，没有切换。"
                return
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func day(_ stamp: String) -> String {
        guard let date = Eidolon.parseTimestamp(stamp) else { return stamp }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
