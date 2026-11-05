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
    /// A reply is being written on the page that opened this one. A past conversation's
    /// own store cannot see it, so the page passes it down (spec #62).
    let currentTurnInFlight: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var affinity: Affinity?
    @State private var draftValue = AffinityRules.normal
    @State private var memoryCount: Int?
    @State private var noEnding = false
    @State private var isSaving = false
    @State private var confirmingReopen = false
    @State private var confirmingMakeCurrent = false
    @State private var errorMessage: String?

    private static let affinityStep = 0.1

    private var busy: Bool { store.isStreaming || currentTurnInFlight || app.call.isLive }

    private enum ConversationState {
        case none
        case currentOngoing
        case currentEnded
        case pastOngoing
        case pastEnded
    }

    private var conversationState: ConversationState {
        guard store.activeConversationID != nil else { return .none }
        if store.isPast { return store.ended ? .pastEnded : .pastOngoing }
        return store.ended ? .currentEnded : .currentOngoing
    }

    private var stateText: String {
        switch conversationState {
        case .none: "还没有对话"
        case .currentOngoing: "当前对话 · 进行中"
        case .currentEnded: "当前对话 · 已结束"
        case .pastOngoing: "历史对话 · 未结束"
        case .pastEnded: "历史对话 · 已结束"
        }
    }

    private var dirty: Bool {
        guard let affinity else { return false }
        return abs(draftValue - affinity.value) >= Self.affinityStep / 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("角色", value: character.name)
                    LabeledContent("这段对话", value: stateText)
                }

                memorySection
                affinitySection
                photoSection
                keepOpenSection
                conversationSection
            }
            .navigationTitle("调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
            .debugErrorAlert($errorMessage)
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
                    DebugMemoryListView(
                        store: store,
                        conversationID: conversationID,
                        currentTurnInFlight: currentTurnInFlight,
                        memoryCount: $memoryCount
                    )
                } label: {
                    LabeledContent(
                        "清除这段对话的记忆",
                        value: memoryCount.map { "\($0) 条" } ?? "…"
                    )
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
                Slider(value: $draftValue, in: 0...100, step: Self.affinityStep) {
                    Text("好感度")
                }
                .accessibilityLabel("好感度")
                .accessibilityValue(
                    String(
                        format: "%.1f，%@",
                        draftValue,
                        AffinityTier.of(draftValue).title
                    )
                )
                HStack {
                    Text("设为 \(String(format: "%.1f", draftValue))")
                        .monospacedDigit()
                    Text(AffinityTier.of(draftValue).title)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("回到 \(Int(AffinityRules.normal))") {
                        draftValue = AffinityRules.normal
                    }
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
            Text(
                busy
                    ? "她正在回复或通话中，保存暂时不可用。设到 0 会开始冷却，设到 0 以上会结束冷却。"
                    : "设到 0 会开始冷却，设到 0 以上会结束冷却。保存只改本机数值，不产生回合、对话事件或好感度变化记录。"
            )
        }
    }

    // MARK: - Keeping this conversation open

    private var photoSection: some View {
        Section {
            Toggle("回复旁显示「生成照片」", isOn: Binding(
                get: { app.debugPhotoButton },
                set: { app.setDebugPhotoButton($0) }
            ))
            .accessibilityIdentifier("debug.photoButton")
        } header: {
            Text("照片")
        } footer: {
            Text("打开后，没生成照片的回复旁会出现一个按钮；点开可以改写照片标签并立刻生成一张，用于测试。")
        }
    }

    private var keepOpenSection: some View {
        Section {
            if store.activeConversationID != nil {
                Toggle("不因好感度下降而结束", isOn: Binding(
                    get: { noEnding },
                    set: { on in
                        noEnding = on
                        Task { await saveNoEnding(on) }
                    }
                ))
                .disabled(busy)
                .accessibilityIdentifier("debug.noEnding")
            } else {
                Text("还没有对话。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("保持对话")
        } footer: {
            Text(
                "开启后，这段对话不会因为冷却、两次越界或累计伤害而结束；通话也不会因此挂断，"
                    + "提示词里也不会再出现「不想聊/挂电话」这类结束方向。"
                    + "好感度照常下降，只对这一条对话有效，新对话默认关闭。"
                    + (busy ? "她正在回复或通话中，先等这一轮结束。" : "")
            )
        }
    }

    // MARK: - Conversation

    private var conversationSection: some View {
        Section {
            switch conversationState {
            case .none:
                Text("还没有对话。")
                    .foregroundStyle(.secondary)
            case .pastOngoing, .pastEnded:
                Button("设为当前对话") { confirmingMakeCurrent = true }
                    .disabled(busy)
            case .currentEnded:
                Button("恢复这段对话") { confirmingReopen = true }
                    .disabled(busy)
            case .currentOngoing:
                Text("这段对话没有结束。")
                    .foregroundStyle(.secondary)
            }
            if busy {
                Text("她正在回复或通话中，写操作等她这一轮结束再做。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("对话")
        } footer: {
            conversationFooter
        }
    }

    @ViewBuilder
    private var conversationFooter: some View {
        switch conversationState {
        case .pastOngoing, .pastEnded:
            Text("设为当前后，下一句会写进这段；原来那段原样变成历史。如果这段已结束，会同时解除结束。")
        case .currentEnded:
            Text("恢复后下一句会写进这段，和从未结束过一样。")
        case .currentOngoing:
            Text("只有被她结束的当前对话需要恢复；历史对话可以设为当前。")
        case .none:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func load() async {
        await loadAffinity()
        await loadMemoryCount()
        await loadNoEnding()
    }

    private func loadAffinity() async {
        do {
            let loaded = try await app.debugAffinity(characterID: character.id)
            affinity = loaded
            draftValue = loaded.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMemoryCount() async {
        guard let conversationID = store.activeConversationID else { return }
        do {
            memoryCount = try await app.debugMemories(conversationID: conversationID).count
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadNoEnding() async {
        guard let conversationID = store.activeConversationID else { return }
        do {
            noEnding = try await app.debugNoEnding(conversationID: conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveNoEnding(_ on: Bool) async {
        guard let conversationID = store.activeConversationID else { return }
        do {
            try await app.setDebugNoEnding(conversationID: conversationID, on: on)
            noEnding = on
        } catch {
            errorMessage = error.localizedDescription
            await loadNoEnding()
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
            let reopened = try await app.reopenDebugConversation(id: id)
            guard reopened else {
                errorMessage = "这段对话已经不在了。"
                return
            }
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

}

private struct DebugErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(
            "出错了",
            isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )
        ) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

private extension View {
    func debugErrorAlert(_ message: Binding<String?>) -> some View {
        modifier(DebugErrorAlert(message: message))
    }
}

/// The memories one conversation wrote down, newest first, with any subset deletable.
struct DebugMemoryListView: View {
    let store: ChatStore
    let conversationID: String
    let currentTurnInFlight: Bool
    @Binding var memoryCount: Int?

    @Environment(AppModel.self) private var app
    @State private var memories: [MemoryRecord] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isDeleting = false
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    private var busy: Bool { store.isStreaming || currentTurnInFlight || app.call.isLive }

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
        .debugErrorAlert($errorMessage)
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
        .accessibilityLabel(
            "\(memory.text)，\(sourceName(memory))，\(Self.day(memory.createdAt))"
                + (memory.holds ? "" : "，已被取代")
        )
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
            memoryCount = memories.count
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

}
