import SwiftUI

@MainActor
struct ChatView: View {
    @Environment(AppModel.self) private var app
    let target: ChatTarget

    @State private var store: ChatStore?

    var body: some View {
        Group {
            if let store {
                ChatContent(store: store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(target.character.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { @MainActor in
            guard store == nil else { return }
            let created = ChatStore(
                client: app.client,
                character: target.character,
                conversationID: target.conversationID
            )
            store = created
            await created.load()
        }
    }
}

private struct ChatContent: View {
    @Bindable var store: ChatStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.items, id: \.uid) { item in
                        row(item)
                    }

                    if let pending = store.pendingUserText {
                        userBubble(pending)
                            .id("pending")
                    }

                    if !store.liveLines.isEmpty {
                        liveBubble
                            .id("live")
                    }

                    if store.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.items.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: store.liveLines.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: store.pendingUserText) { _, _ in scrollToBottom(proxy) }
        }
        .safeAreaInset(edge: .bottom) {
            inputBar
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func row(_ item: RecordItem) -> some View {
        if item.isEvent {
            Text(item.eventDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        } else if item.isCharacter {
            characterBubble(
                ja: item.japanese,
                zh: item.chinese,
                reachOut: item.isReachOut
            )
        } else {
            userBubble(item.text ?? "")
        }
    }

    private func characterBubble(ja: String, zh: String, reachOut: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if reachOut {
                    Text("她先开口")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !ja.isEmpty {
                    Text(ja)
                        .font(.body)
                }
                if !zh.isEmpty && zh != ja {
                    Text(zh)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Color(hex: store.character.color).opacity(0.15),
                in: RoundedRectangle(cornerRadius: 16)
            )

            Spacer(minLength: 40)
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack(alignment: .top) {
            Spacer(minLength: 40)

            Text(text)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Color.accentColor.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 16)
                )
        }
    }

    private var liveBubble: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.liveLines) { line in
                    if !line.ja.isEmpty {
                        Text(line.ja)
                            .font(.body)
                    }
                    if !line.zh.isEmpty && line.zh != line.ja {
                        Text(line.zh)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("正在说…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Color(hex: store.character.color).opacity(0.15),
                in: RoundedRectangle(cornerRadius: 16)
            )

            Spacer(minLength: 40)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("和她说点什么…", text: $store.draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18)
                )

            if store.isSending {
                ProgressView()
                    .frame(width: 34, height: 34)
            } else {
                Button {
                    Task { await store.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { shown in
                if !shown { store.errorMessage = nil }
            }
        )
    }
}
