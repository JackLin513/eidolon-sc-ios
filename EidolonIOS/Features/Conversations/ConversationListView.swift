import EidolonCore
import SwiftUI

/// The roster: who she is, the latest thing she said, and whether she reached
/// out while you were away. Chat arrives in the next ticket.
struct ConversationListView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var showSettings = false
    @State private var path: [CharacterConfig] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(filtered, id: \.id) { character in
                NavigationLink(value: character) {
                    row(character)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "搜中文名、假名、罗马字或组合")
            .navigationTitle("对话")
            .refreshable { await app.refresh() }
            .navigationDestination(for: CharacterConfig.self) { character in
                ChatView(character: character)
            }
            .task { await app.refresh() }
            .onAppear {
                #if DEBUG
                if app.debugShowsMemories || app.debugShowsTraces || app.debugShowsStandPreview {
                    showSettings = true
                }
                if path.isEmpty,
                   let id = app.debugCharacterID,
                   let character = app.characters.first(where: { $0.id == id }) {
                    path = [character]
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .overlay {
                if app.characters.isEmpty {
                    ContentUnavailableView(
                        "没有角色",
                        systemImage: "person.2",
                        description: Text("这份内容包里没有角色")
                    )
                }
            }
            .alert("出错了", isPresented: errorBinding) {
                Button("好") { app.errorMessage = nil }
            } message: {
                Text(app.errorMessage ?? "")
            }
        }
    }

    private var filtered: [CharacterConfig] {
        // Most recent activity first; ties keep the content's own order (upstream `arrange`).
        let ordered = ConversationOrder.byRecency(app.characters, latest: app.latest)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ordered }
        return ordered.filter { $0.matches(needle) }
    }

    private func row(_ character: CharacterConfig) -> some View {
        HStack(spacing: 12) {
            avatar(character)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(character.name)
                        .font(.headline)
                    if app.latest[character.id]?.unseenReachOut == true {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    }
                }
                if !character.subtitle.isEmpty {
                    Text(character.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(preview(character))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func avatar(_ character: CharacterConfig) -> some View {
        if let image = app.avatar(for: character.id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color(hex: character.color ?? "#888888").opacity(0.35))
                .frame(width: 46, height: 46)
                .overlay {
                    Text(String(character.name.prefix(1)))
                        .font(.headline)
                }
        }
    }

    private func preview(_ character: CharacterConfig) -> String {
        guard let activity = app.latest[character.id] else { return character.intro ?? "" }
        // The last thing in the conversation may be something that happened, not said.
        if let kind = activity.lastEventKind { return Self.eventPreview(kind) }
        return activity.lastMessagePreview ?? "还没聊过"
    }

    private static func eventPreview(_ kind: String) -> String {
        ConversationEventKind(stored: kind).displayText
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { app.errorMessage != nil && !app.characters.isEmpty },
            set: { shown in
                if !shown { app.errorMessage = nil }
            }
        )
    }
}
