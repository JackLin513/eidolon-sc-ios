import EidolonCore
import SwiftUI
import UIKit

/// The gift page (spec #65): today's draw chances, what the last draws gave, the
/// backpack, and the reset card. Giving a gift to her arrives with #66; the route from
/// her chat already preselects her here.
struct GiftsView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: GiftCategory?
    @State private var pageAlert: GiftPageAlert?
    @State private var isDebuggingDraws = false
    @State private var isLoading = true
    @State private var giftToGive: Gift?
    @State private var pendingSent: GiftSentNotice?
    @State private var resetTargets: [ResetCardTarget] = []
    @State private var confirmingReset = false

    private var chosen: CharacterConfig? {
        guard let id = app.giftPreselection else { return nil }
        return app.characters.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let state = app.giftState {
                if state.catalogMissing {
                    missingCatalog
                } else {
                    content(state)
                }
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "礼物暂时打不开",
                    systemImage: "gift",
                    description: Text("先导入内容包，再回来看礼物。")
                )
            }
        }
        .navigationTitle("礼物")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if app.debugMode {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isDebuggingDraws = true
                    } label: {
                        Image(systemName: "hammer")
                    }
                    .accessibilityLabel("调试抽奖次数")
                    .accessibilityIdentifier("gifts.debug")
                }
            }
        }
        .sheet(isPresented: $isDebuggingDraws) {
            GiftDrawDebugSheet()
                .environment(app)
        }
        .sheet(item: $giftToGive, onDismiss: {
            if let pendingSent {
                self.pendingSent = nil
                pageAlert = .sent(pendingSent)
            }
        }) { gift in
            GiftRecipientSheet(gift: gift, preselected: chosen?.id) { given in
                pendingSent = GiftSentNotice(given: given)
            }
            .environment(app)
        }
        .alert(item: $pageAlert) { alert in
            switch alert {
            case let .simple(title, message):
                Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            case let .sent(notice):
                Alert(
                    title: Text("送给\(notice.name)了"),
                    message: Text(notice.message),
                    primaryButton: .default(Text("去对话")) {
                        app.openConversation(characterID: notice.given.characterID)
                        Task { await load() }
                    },
                    secondaryButton: .cancel(Text("好")) {
                        Task { await load() }
                    }
                )
            case let .reset(message):
                Alert(
                    title: Text("重置卡"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Sections

    private func content(_ state: GiftState) -> some View {
        List {
            if app.call.isLive {
                Section {
                    Label("通话中，挂断后才能送礼", systemImage: "phone.down")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("gifts.callNotice")
                }
            }
            if let chosen {
                preselection(chosen)
            }
            chances(state)
            if let draw = app.lastGiftDraw, !draw.results.isEmpty {
                lastDraw(draw)
            }
            backpack(state)
            resetCards(state)
        }
        .listStyle(.insetGrouped)
    }

    private func preselection(_ character: CharacterConfig) -> some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("给\(character.name)挑一件礼物")
                        .font(.headline)
                    Text("从背包里选一件送她，回礼和好感会在送她时出现。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("去对话") {
                    app.openConversation(characterID: character.id)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("gifts.goToConversation")
            }
        }
    }

    private func chances(_ state: GiftState) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("剩余抽奖次数")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(state.draws) / \(state.maxDraws)")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .accessibilityIdentifier("gifts.draws")
                    }
                    Spacer()
                    Text("每天 0 点补 2 次，最多攒 \(state.maxDraws) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                ProgressView(value: Double(state.draws), total: Double(state.maxDraws))
                Label("下次补发 \(refillText(state.nextRefill))", systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            HStack(spacing: 12) {
                Button {
                    draw(all: false)
                } label: {
                    Label("抽一次", systemImage: "dice")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                        // The prominent fill is the tint colour; a tinted symbol would
                        // disappear into it. White is what the title already uses.
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.draws == 0 || app.isGiftWorking)
                .accessibilityIdentifier("gifts.drawOne")

                Button {
                    draw(all: true)
                } label: {
                    Text("抽完 \(state.draws) 次")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(state.draws == 0 || app.isGiftWorking)
                .accessibilityIdentifier("gifts.drawAll")
            }

            if state.draws == 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Label("今天的次数用完了", systemImage: "hourglass")
                        .font(.subheadline)
                    Text("明天 0 点补 2 次，最多攒 7 次。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("gifts.noDraws")
            }
        } header: {
            Text("抽奖")
        } footer: {
            Text("每次抽奖有 1% 的机会得到重置卡；其余是普通、少见或稀有的礼物。")
        }
    }

    private func lastDraw(_ draw: GiftDraw) -> some View {
        Section("这次抽到") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(draw.results.enumerated()), id: \.offset) { _, result in
                        resultCard(result)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        }
    }

    private func resultCard(_ result: GiftDrawResult) -> some View {
        VStack(spacing: 8) {
            GiftArtwork(url: artURL(result), symbol: symbol(result))
            Text(result.gift?.name ?? "重置卡")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(result.gift?.rarity.title ?? "把低于信任的角色拉回 50")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 96)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "gifts.result.\(result.gift?.id ?? GiftRules.resetCardID)"
        )
    }

    private func backpack(_ state: GiftState) -> some View {
        let stacks = filtered(state.backpack)
        return Section {
            filterBar
            if stacks.isEmpty {
                ContentUnavailableView(
                    filter == nil ? "背包还是空的" : "这一类还没有礼物",
                    systemImage: "bag",
                    description: Text(
                        filter == nil
                            ? "抽一次礼物，抽到的东西会放在这里。"
                            : "换一个类别看看。"
                    )
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(stacks) { stack in
                    backpackRow(stack)
                }
            }
        } header: {
            Text("我的礼物")
        } footer: {
            Text("同一种礼物会叠在一起；送出去的礼物从背包里减少。")
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", selected: filter == nil) { filter = nil }
                ForEach(GiftCategory.allCases, id: \.self) { category in
                    chip(category.title, selected: filter == category) {
                        filter = category
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(Color.clear)
    }

    private func chip(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemFill))
                )
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func backpackRow(_ stack: GiftStack) -> some View {
        Button {
            giftToGive = stack.gift
        } label: {
            HStack(spacing: 12) {
                GiftArtwork(
                    url: app.core.giftArtURL(for: stack.gift.id),
                    symbol: symbol(stack.gift.category),
                    size: 48
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(stack.gift.name)
                        .font(.body)
                    HStack(spacing: 4) {
                        Text(stack.gift.category.title)
                        Text("·")
                        Text(stack.gift.rarity.title)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("×\(stack.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(app.call.isLive)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gifts.backpack.\(stack.gift.id)")
    }

    private func resetCards(_ state: GiftState) -> some View {
        Section {
            HStack(spacing: 12) {
                GiftArtwork(
                    url: app.core.resetCardArtURL(),
                    symbol: "arrow.counterclockwise.circle.fill",
                    size: 48
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("重置卡 ×\(state.resetCards)")
                        .font(.headline)
                    Text(
                        resetTargets.isEmpty
                            ? "现在没有需要拉回的角色"
                            : "现在用会拉回 \(resetTargets.count) 位"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("使用") {
                    confirmingReset = true
                }
                .buttonStyle(.bordered)
                .disabled(state.resetCards == 0 || resetTargets.isEmpty || app.isGiftWorking)
                .accessibilityIdentifier("gifts.useResetCard")
            }
            if state.resetCards == 0 {
                Label("抽奖有 1% 的机会得到重置卡", systemImage: "arrow.counterclockwise.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("重置卡")
        } footer: {
            Text("把所有低于信任（冷淡、疏远）的角色拉回 50 并解除冷却；信任及以上不动。不写对话，也不触发成就。")
        }
        .confirmationDialog(
            "把她们拉回信任？",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("使用一张重置卡") { useResetCard() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                resetTargets.map {
                    "\($0.name)：\($0.tier.title)" + ($0.cooling ? "（冷却中）" : "") + " → 信任"
                }.joined(separator: "\n")
            )
        }
    }

    private var missingCatalog: some View {
        ScrollView {
            VStack(spacing: 24) {
                ContentUnavailableView {
                    Label("内容包没有礼物目录", systemImage: "gift")
                } description: {
                    Text(
                        "这份内容包是旧版导出的，抽奖和背包暂时用不了。"
                            + "用新版导出脚本重新导出并导入后，礼物就会出现在这里；对话不受影响。"
                    )
                }
                if let chosen {
                    Button("回到\(chosen.name)的对话") {
                        app.openConversation(characterID: chosen.id)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("gifts.goToConversation")
                }
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await app.refreshGifts()
            resetTargets = try await app.resetCardTargets()
            await app.markGiftRewardsSeen()
            await app.markPlaySeen()
        } catch {
            pageAlert = .simple("礼物", error.localizedDescription)
        }
    }

    private func useResetCard() {
        Task {
            do {
                let use = try await app.useResetCard()
                resetTargets = try await app.resetCardTargets()
                pageAlert = .reset(
                    "已把 \(use.restored.count) 位拉回信任。还剩 \(use.resetCardsLeft) 张。"
                )
            } catch {
                // The card was not taken, but what can still be pulled back may have
                // changed while the dialog was up.
                try? await app.refreshGifts()
                resetTargets = (try? await app.resetCardTargets()) ?? resetTargets
                pageAlert = .reset(error.localizedDescription)
            }
        }
    }

    private func draw(all: Bool) {
        Task {
            do {
                _ = try await app.drawGifts(all: all)
            } catch {
                pageAlert = .simple("礼物", error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func filtered(_ stacks: [GiftStack]) -> [GiftStack] {
        guard let filter else { return stacks }
        return stacks.filter { $0.gift.category == filter }
    }

    private func refillText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = GiftRules.dayTimeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func artURL(_ result: GiftDrawResult) -> URL? {
        switch result {
        case let .gift(gift): app.core.giftArtURL(for: gift.id)
        case .resetCard: app.core.resetCardArtURL()
        }
    }

    private func symbol(_ result: GiftDrawResult) -> String {
        switch result {
        case let .gift(gift): symbol(gift.category)
        case .resetCard: "arrow.counterclockwise.circle.fill"
        }
    }

    private func symbol(_ category: GiftCategory) -> String {
        switch category {
        case .food: "fork.knife"
        case .drink: "cup.and.saucer.fill"
        case .flower: "leaf.fill"
        case .trinket: "sparkles"
        }
    }
}

private struct GiftSentNotice: Identifiable {
    let id = UUID()
    let given: GiftGiven
    var name: String {
        given.gift.name
    }
    var message: String {
        let feeling: String
        if given.stillCooling {
            feeling = "她还在冷却。"
        } else if given.change != nil {
            feeling = "好感度上升了，现在是\(given.tier.title)。"
        } else {
            feeling = "她收下了。"
        }
        return "\(feeling)背包里还剩 \(given.remaining) 件。"
    }
}

/// The characters a gift may go to, in the roster's order, with her tier and cooldown;
/// what she likes is never shown (spec #66).
private struct GiftRecipientSheet: View {
    let gift: Gift
    let preselected: String?
    let onGiven: (GiftGiven) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var recipients: [GiftRecipient] = []
    @State private var selected: String?
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?

    private var ordered: [GiftRecipient] {
        // The preselected one first, both groups keeping the roster's order.
        recipients.filter { $0.characterID == preselected }
            + recipients.filter { $0.characterID != preselected }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        GiftArtwork(
                            url: app.core.giftArtURL(for: gift.id),
                            symbol: "gift",
                            size: 54
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gift.name)
                                .font(.headline)
                            Text("\(gift.category.title) · \(gift.rarity.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if app.call.isLive {
                    Section {
                        Label("通话中，挂断后才能送礼", systemImage: "phone.down")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    if isLoading {
                        ProgressView()
                    } else {
                        ForEach(ordered) { recipient in
                            Button {
                                selected = recipient.characterID
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recipient.name)
                                            .foregroundStyle(.primary)
                                        Text(
                                            recipient.cooling
                                                ? "\(recipient.tier.title) · 冷却中"
                                                : recipient.tier.title
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if selected == recipient.characterID {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(app.call.isLive)
                            .accessibilityIdentifier("gifts.recipient.\(recipient.characterID)")
                        }
                    }
                } header: {
                    Text("送给谁")
                } footer: {
                    Text("看不到她喜欢什么；送出后才会知道。")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("送礼物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "送出中…" : "送出") { send() }
                        .disabled(
                            selected == nil || isSending || isLoading || app.call.isLive
                        )
                        .accessibilityIdentifier("gifts.send")
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            recipients = try await app.giftRecipients()
            selected = preselected ?? recipients.first?.characterID
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func send() {
        guard let selected else { return }
        Task {
            isSending = true
            defer { isSending = false }
            do {
                let given = try await app.giveGift(giftID: gift.id, characterID: selected)
                onGiven(given)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// The gift page's debug sheet (only reachable while debug mode is on): adds draw
/// chances with no cap, without drawing anything.
private struct GiftDrawDebugSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draws: Int?
    @State private var amount = 1
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("剩余抽奖次数")
                        Spacer()
                        Text(draws.map(String.init) ?? "…")
                            .monospacedDigit()
                            .accessibilityIdentifier("gifts.debug.draws")
                    }
                }
                Section {
                    Button("加 1 次") { add(1) }
                        .disabled(isAdding)
                        .accessibilityIdentifier("gifts.debug.addOne")
                    Button("加 10 次") { add(10) }
                        .disabled(isAdding)
                        .accessibilityIdentifier("gifts.debug.addTen")
                    Stepper(value: $amount, in: 1...1000) {
                        Text("自定义 \(amount) 次")
                    }
                    Button("追加 \(amount) 次") { add(amount) }
                        .disabled(isAdding)
                        .accessibilityIdentifier("gifts.debug.addCustom")
                } footer: {
                    Text("只追加次数，不抽奖、不进背包，也不计入「抽过的奖」成就；不限上限。")
                }
            }
            .navigationTitle("调试：抽奖次数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                do {
                    draws = try await app.debugGiftDraws()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .alert(
                "调试",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium])
    }

    private func add(_ count: Int) {
        Task {
            isAdding = true
            defer { isAdding = false }
            do {
                draws = try await app.debugAddGiftDraws(count)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A gift's picture, or the category's symbol when the bundle has no art for it.
private struct GiftArtwork: View {
    let url: URL?
    let symbol: String
    var size: CGFloat = 96
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: url) {
            image = nil
            guard let url else { return }
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
            image = data.flatMap(UIImage.init(data:))
        }
        .accessibilityHidden(true)
    }
}

private enum GiftPageAlert: Identifiable {
    case simple(String, String)
    case sent(GiftSentNotice)
    case reset(String)

    var id: String {
        switch self {
        case let .simple(title, message): "simple:\(title):\(message)"
        case let .sent(notice): "sent:\(notice.id)"
        case let .reset(message): "reset:\(message)"
        }
    }
}
