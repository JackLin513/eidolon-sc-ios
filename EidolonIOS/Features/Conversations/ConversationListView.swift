import SwiftUI

struct ConversationListView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var path: [ChatTarget] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(filtered) { character in
                    Button {
                        Task {
                            if let target = await app.open(character) {
                                path.append(target)
                            }
                        }
                    } label: {
                        row(character)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "搜中文名、假名、罗马字或组合")
            .navigationTitle("对话")
            .refreshable { await app.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(for: ChatTarget.self) { target in
                ChatView(target: target)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .overlay {
                if app.characters.isEmpty {
                    emptyState
                }
            }
            .alert("出错了", isPresented: errorBinding) {
                Button("好") { app.errorMessage = nil }
            } message: {
                Text(app.errorMessage ?? "")
            }
        }
    }

    private var filtered: [Character] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return app.characters }
        return app.characters.filter { character in
            [
                character.name,
                character.nameZh ?? "",
                character.nameKana ?? "",
                character.nameRomaji ?? "",
                character.unit ?? "",
                character.intro,
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(needle)
        }
    }

    private func row(_ character: Character) -> some View {
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
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func avatar(_ character: Character) -> some View {
        if let url = app.client.absoluteURL(character.avatarUrl) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle()
                        .fill(Color(hex: character.color).opacity(0.35))
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color(hex: character.color).opacity(0.35))
                .frame(width: 46, height: 46)
                .overlay {
                    Text(String(character.name.prefix(1)))
                        .font(.headline)
                }
        }
    }

    private func preview(_ character: Character) -> String {
        guard let latest = app.latest[character.id] else { return character.intro }
        return latest.lastMessage?.preview ?? "还没聊过"
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = app.errorMessage, !error.isEmpty {
            ContentUnavailableView(
                "连不上后端",
                systemImage: "wifi.exclamationmark",
                description: Text(error)
            )
        } else {
            ContentUnavailableView(
                "没有角色",
                systemImage: "person.2",
                description: Text("后端没有返回角色配置")
            )
        }
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
