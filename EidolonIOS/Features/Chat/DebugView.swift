import EidolonCore
import Foundation
import SwiftUI

/// The character page's debug sheet (spec #62): the three things that are otherwise slow
/// or impossible to reach on a device — a conversation's memories, her affinity, and an
/// ended or past conversation. Every write is disabled while a turn or a call is using the
/// same library.
struct DebugView: View {
    let character: CharacterConfig
    let store: ChatStore

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var affinity: Affinity?
    @State private var draftValue = AffinityRules.normal
    @State private var isSaving = false
    @State private var confirmingReopen = false
    @State private var confirmingMakeCurrent = false
    @State private var errorMessage: String?

    private var busy: Bool { store.isStreaming || app.call.isLive }

    private var dirty: Bool {
        guard let affinity else { return false }
        return abs(draftValue - affinity.value) > 0.05
    }

    private var stateText: String {
        guard store.activeConversationID != nil else { return "还没有对话" }
        let kind = store.isPast ? "历史对话" : "当前对话"
        return store.ended ? "\(kind) · 已结束" : kind
    }

    var body: some View {
        NavigationStack {
            Form {
                memorySection
                affinitySection
                conversationSection
            }
            .navigationTitle("调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await loadAffinity() }
            .alert("出错了", isPresented: errorBinding) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog(
                "恢复这段对话？",
                isPresented: $confirmingReopen,
                titleVisibility: .visible
            ) {
                Button("恢复") {
                    Task { await reopen() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会清除结束状态和「她结束了对话」的记录，之后可以继续在这段里说话。")
            }
            .confirmationDialog(
                "设为当前对话？",
                isPresented: $confirmingMakeCurrent,
                titleVisibility: .visible
            ) {
                Button("设为当前") {
                    Task { await makeCurrent() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("原来那段会变成历史对话。如果这段已经结束，会同时解除结束。")
            }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        Section {
            if let conversationID = store.activeConversationID {
                NavigationLink {
                    DebugMemoryListView(store: store, conversationID: conversationID)
                } label: {
                    Text("清除这段对话的记忆")
                }
            } else {
                Text("还没有对话，也没有这段对话的记忆。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("记忆")
        } footer: {
            Text("记忆是跨角色共享的：在一位偶像这里删掉，所有偶像都不再想起。")
        }
    }

    // MARK: - Affinity

    private var affinitySection: some View {
        Section {
            if let affinity {
                HStack {
                    Text("当前")
                    Spacer()
                    Text(String(format: "%.1f", affinity.value))
                        .monospacedDigit()
                    Text(AffinityTier.of(affinity.value).title)
                        .foregroundStyle(.secondary)
                    if affinity.cooling {
                        Text("冷却中")
                            .foregroundStyle(.blue)
                    }
                }
                Slider(value: $draftValue, in: 0...100, step: 0.1) {
                    Text("好感度")
                }
                .accessibilityLabel("好感度")
                .accessibilityValue(String(format: "%.1f，%@", draftValue, AffinityTier.of(draftValue).title))
                HStack {
                    Text("设为 \(String(format: "%.1f", draftValue))")
                        .monospacedDigit()
                    Text(AffinityTier.of(draftValue).title)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("回到 50") { draftValue = AffinityRules.normal }
                        .disabled(busy)
                }
                Button("保存") {
                    Task { await saveAffinity() }
                }
                .disabled(busy || isSaving || !dirty)
                .accessibilityIdentifier("debug.affinity.save")
            } else {
                ProgressView()
            }
        } header: {
            Text("好感度")
        } footer: {
            Text("设到 0 会开始冷却，设到 0 以上会结束冷却。保存只改本机数值，不产生回合、对话事件或好感度变化记录。")
        }
    }

    // MARK: - Conversation

    private var conversationSection: some View {
        Section {
            LabeledContent("这段对话", value: stateText)
            if let conversationID = store.activeConversationID {
                if store.isPast {
                    Button("设为当前对话") { confirmingMakeCurrent = true }
                        .disabled(busy)
                } else if store.ended {
                    Button("恢复这段对话") { confirmingReopen = true }
                        .disabled(busy)
                }
                if busy {
                    Text("她正在回复或通话中，写操作等她这一轮结束再做。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // The id is shown only to make it unmistakable which conversation the
                // debug actions land on; it is not part of the normal page.
                Text(conversationID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("对话")
        } footer: {
            if store.isPast {
                Text("设为当前后，下一句会写进这段；原来那段原样变成历史。")
            } else if store.ended {
                Text("恢复后下一句会写进这段，和从未结束过一样。")
            } else if store.activeConversationID != nil {
                Text("这段对话没有被她结束。")
            }
        }
    }

    // MARK: - Actions

    private func loadAffinity() async {
        do {
            let loaded = try await app.debugAffinity(characterID: character.id)
            affinity = loaded
            draftValue = loaded.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAffinity() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.setDebugAffinity(characterID: character.id, value: draftValue)
            await loadAffinity()
            await store.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reopen() async {
        guard let id = store.activeConversationID else { return }
        do {
            _ = try await app.reopenDebugConversation(id: id)
            await store.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeCurrent() async {
        guard let id = store.activeConversationID else { return }
        do {
            let moved = try await app.setDebugCurrentConversation(
                characterID: character.id,
                id: id,
                reopen: store.ended
            )
            guard moved else {
                errorMessage = "这段对话不属于这位角色，没有切换。"
                return
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

/// The memories one conversation wrote down, newest first, with any subset deletable.
struct DebugMemoryListView: View {
    let store: ChatStore
    let conversationID: String

    @Environment(AppModel.self) private var app
    @State private var memories: [MemoryRecord] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isDeleting = false
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    private var busy: Bool { store.isStreaming || app.call.isLive }

    private var names: [String: String] {
        Dictionary(uniqueKeysWithValues: app.characters.map { ($0.id, $0.name) })
    }

    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .listRowBackground(Color.clear)
            } else if memories.isEmpty {
                ContentUnavailableView(
                    "这段对话没有记忆",
                    systemImage: "brain",
                    description: Text("她还没有从这段对话里记住什么。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(memories) { memory in
                    row(memory)
                }
            }
        }
        .navigationTitle("这段对话的记忆")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            deleteBar
        }
        .task { await load() }
        .confirmationDialog(
            selected.isEmpty ? "删除所选的记忆？" : "删除所选的 \(selected.count) 条记忆？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("记忆是跨角色共享的，删除后所有偶像都不再想起；不能撤销。")
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ memory: MemoryRecord) -> some View {
        let picked = selected.contains(memory.id)
        return Button {
            if picked {
                selected.remove(memory.id)
            } else {
                selected.insert(memory.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked ? Color.accentColor : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(memory.text)
                        .foregroundStyle(memory.holds ? .primary : .secondary)
                    HStack(spacing: 6) {
                        Text(sourceName(memory))
                        Text(Self.day(memory.createdAt))
                        if !memory.holds {
                            Text("已被取代")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(memory.text)，\(sourceName(memory))，\(Self.day(memory.createdAt))\(memory.holds ? "" : "，已被取代")")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var deleteBar: some View {
        VStack(spacing: 6) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text(selected.isEmpty ? "删除所选" : "删除所选（\(selected.count)）")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty || busy || isDeleting)
            .accessibilityIdentifier("debug.memory.delete")
            Text(
                busy
                    ? "她正在回复或通话中，等她这一轮结束再删。"
                    : "记忆是跨角色共享的：删掉后所有偶像都不再想起。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func load() async {
        do {
            memories = try await app.debugMemories(conversationID: conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteSelected() async {
        guard !selected.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await app.deleteDebugMemories(ids: Array(selected))
            selected.removeAll()
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sourceName(_ memory: MemoryRecord) -> String {
        guard let id = memory.sourceCharacterID else { return "来源未知" }
        return names[id] ?? id
    }

    private static func day(_ stamp: String) -> String {
        guard let date = Eidolon.parseTimestamp(stamp) else { return stamp }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
