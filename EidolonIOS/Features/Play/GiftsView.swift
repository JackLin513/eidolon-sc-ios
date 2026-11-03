import EidolonCore
import SwiftUI
import UIKit

/// The gift page (spec #65): today's draw chances, what the last draws gave, the
/// backpack, and the reset card. Giving a gift to her arrives with #66; the route from
/// her chat already preselects her here.
struct GiftsView: View {
    @Environment(AppModel.self) private var app
    @State private var filter: GiftCategory?
    @State private var alert: GiftAlert?
    @State private var isLoading = true

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
        .task { await load() }
        .refreshable { await load() }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    // MARK: - Sections

    private func content(_ state: GiftState) -> some View {
        List {
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gifts.backpack.\(stack.gift.id)")
    }

    private func resetCards(_ state: GiftState) -> some View {
        Section {
            LabeledContent("持有", value: "\(state.resetCards) 张")
            Label("抽奖有 1% 的机会得到重置卡", systemImage: "arrow.counterclockwise.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("重置卡")
        } footer: {
            Text("重置卡不占背包；抽到后会存在这里。")
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
        } catch {
            alert = GiftAlert(title: "礼物", message: error.localizedDescription)
        }
    }

    private func draw(all: Bool) {
        Task {
            do {
                _ = try await app.drawGifts(all: all)
            } catch {
                alert = GiftAlert(title: "礼物", message: error.localizedDescription)
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

private struct GiftAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
