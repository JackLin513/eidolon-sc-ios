import EidolonCore
import SwiftUI

/// What the bar's card says under its name.
enum BarEntry {
    /// Before its package is in: the bar cannot be drawn without it.
    static let importHint = "还没有导入酒吧素材包，进设置导入"
    static let rewardToday = "今天第一次光顾有奖励"
    static let rewardTaken = "今天的奖励领过了"
}

/// The play tab's first page (spec #64): the bar, which moved here from the roster, the
/// gift page, and the achievement page that a later ticket fills in.
struct PlayHubView: View {
    @Environment(AppModel.self) private var app
    @State private var isBarShown = false

    private var playPath: Binding<NavigationPath> {
        Binding(get: { app.playPath }, set: { app.playPath = $0 })
    }

    var body: some View {
        // The folded call's bar stands on top of the tab's navigation, not inside its
        // scroll view: inside, the iOS 26 navigation bar tints itself with the bar's dark
        // background and the title disappears (spec #64).
        VStack(spacing: 0) {
            CallBar()
            NavigationStack(path: playPath) {
                List {
                    Section {
                        card(
                            icon: "gift",
                            title: "礼物",
                            subtitle: "抽奖、背包和送她的礼物"
                        ) {
                            app.openGifts()
                        }
                        .accessibilityIdentifier("play.gifts")

                        card(
                            icon: "trophy",
                            title: "成就",
                            subtitle: "和她们的进度"
                        ) {
                            app.playPath = NavigationPath()
                            app.playPath.append(PlayRoute.achievements)
                        }
                        .accessibilityIdentifier("play.achievements")

                        card(
                            icon: "wineglass",
                            title: "酒吧",
                            subtitle: barSubtitle
                        ) {
                            openBar()
                        }
                        .accessibilityIdentifier("play.bar")
                    }
                }
                .listStyle(.plain)
                .navigationTitle("玩法")
                .navigationDestination(for: PlayRoute.self) { route in
                    switch route {
                    case .gifts:
                        GiftsView()
                    case .achievements:
                        PlayPlaceholderView(
                            title: "成就",
                            systemImage: "trophy",
                            description: "成就页会在后续版本接入。"
                        )
                    }
                }
                // 酒吧整屏呈现：面包屑、横向画面和它的安全区都留在酒吧自己手里。
                .fullScreenCover(isPresented: $isBarShown) {
                    BarRoomView(
                        settings: BarSettings.stored(app.barSettingsValue),
                        jukebox: app.barJukeboxState,
                        tutorialWalked: app.barTutorialDone
                    )
                }
                .task {
                    if app.consumeDebugBarRequest() {
                        isBarShown = true
                    }
                }
            }
        }
    }

    private func openBar() {
        guard app.barInfo != nil else {
            app.openSettings()
            return
        }
        isBarShown = true
    }

    /// The bar's line under its name: the way to bring its package in, today's reward, or
    /// that today's has been taken.
    private var barSubtitle: String {
        guard app.barInfo != nil else { return BarEntry.importHint }
        return app.barRewardToday ? BarEntry.rewardToday : BarEntry.rewardTaken
    }

    private func card(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// A page in the play tab that later tickets replace.
struct PlayPlaceholderView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView(
            "\(title)即将开放",
            systemImage: systemImage,
            description: Text(description)
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
