import EidolonCore
import SwiftUI
import UIKit

/// The play tab's first page (spec #64, #94): five cards in the upstream order — gifts,
/// achievements, calendar, her cycles, the bar — with what each holds read once on the page.
struct PlayHubView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.barOrientation) private var barOrientation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var summaryFailed = false
    @State private var isBarShown = false
    /// The bar is a landscape screen. The play page turns first and is covered while it
    /// does, so the bar never appears half-turned; on the way back it stays covered until
    /// the page is upright again.
    @State private var isEnteringBar = false
    @State private var isLeavingBar = false

    private var playPath: Binding<NavigationPath> {
        Binding(get: { app.playPath }, set: { app.playPath = $0 })
    }

    var body: some View {
        // The folded call's bar floats over the empty part of the large-title header, so
        // it does not move the title (bug 2026-11-04). Subpages keep their inline
        // navigation untouched; the bar is only on the first-level page.
        NavigationStack(path: playPath) {
                Group {
                    if let summary = app.playSummary {
                        cards(summary.cards)
                    } else if summaryFailed {
                        ContentUnavailableView {
                            Label("玩法暂时打不开", systemImage: "sparkles")
                        } description: {
                            Text("稍后再试。")
                        } actions: {
                            Button("重试") { Task { await load() } }
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .navigationTitle("玩法")
                .navigationDestination(for: PlayRoute.self) { route in
                    switch route {
                    case .gifts:
                        GiftsView()
                    case .achievements:
                        AllAchievementsView()
                    case .calendar:
                        CalendarView()
                    case let .schedule(characterID):
                        SchedulePageView(characterID: characterID)
                    case .cycles:
                        CyclesView()
                    }
                }
                // 酒吧整屏呈现：面包屑、横向画面和它的安全区都留在酒吧自己手里。
                .fullScreenCover(
                    isPresented: $isBarShown,
                    onDismiss: { finishLeavingBar() }
                ) {
                    BarRoomView(
                        settings: BarSettings.stored(app.barSettingsValue),
                        jukebox: app.barJukeboxState,
                        tutorialWalked: app.barTutorialDone,
                        onLeaving: { beginLeavingBar() }
                    )
                }
                .task {
                    await load()
                    if app.consumeDebugBarRequest() {
                        openBar()
                    }
                }
            }
            .overlay(alignment: .top) {
                if app.playPath.isEmpty {
                    CallBar()
                }
            }
        .background { TabBarHides(hidden: isEnteringBar || isLeavingBar) }
        .overlay {
            if isEnteringBar || isLeavingBar {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView(isEnteringBar ? "正在进入酒吧…" : "正在返回…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func load() async {
        summaryFailed = !(await app.refreshPlaySummary())
        await app.refreshAchievementBadge()
    }

    private func cards(_ cards: [PlayCardStatus]) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                if let first = cards.first {
                    card(first, filled: true)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(cards.dropFirst()) { status in
                        card(status, filled: false)
                    }
                }
            }
            .padding(16)
        }
    }

    /// One column on a phone; two on anything wide, never three.
    private var columns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            : [GridItem(.flexible())]
    }

    private func card(_ status: PlayCardStatus, filled: Bool) -> some View {
        Button {
            open(status.kind)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(status.kind))
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle().fill(filled ? Color(.systemBackground) : Color(.secondarySystemBackground))
                    )
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(status.title)
                            .font(.headline)
                        if status.isNew {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("有新内容")
                        }
                    }
                    Text(status.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 18, alignment: .leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(filled ? Color(.secondarySystemBackground) : Color(.systemBackground))
            )
            .overlay {
                if !filled {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(status.title)，\(status.status)" + (status.isNew ? "，有新内容" : "")
        )
        .accessibilityIdentifier("play.\(status.kind.rawValue)")
    }

    private func icon(_ kind: PlayCardKind) -> String {
        switch kind {
        case .gifts: "gift"
        case .achievements: "trophy"
        case .calendar: "calendar"
        case .cycles: "drop"
        case .bar: "wineglass"
        }
    }

    private func open(_ kind: PlayCardKind) {
        switch kind {
        case .gifts:
            app.openGifts()
        case .achievements:
            app.playPath = NavigationPath()
            app.playPath.append(PlayRoute.achievements)
        case .calendar:
            app.playPath.append(PlayRoute.calendar)
        case .cycles:
            app.playPath.append(PlayRoute.cycles)
        case .bar:
            openBar()
        }
    }

    private func openBar() {
        guard app.barInfo != nil else {
            app.openSettings()
            return
        }
        guard !isBarShown, !isEnteringBar, !isLeavingBar else { return }
        isEnteringBar = true
        barOrientation.landscape()
        Task {
            await waitForOrientation(landscape: true)
            isBarShown = true
            // The cover is up now; the black page behind it can go.
            try? await Task.sleep(for: .milliseconds(450))
            isEnteringBar = false
        }
    }

    /// Called as the bar starts to go away, before its dismissal animation reveals the
    /// play page (and again from its `onDisappear` if a call took it away).
    private func beginLeavingBar() {
        isLeavingBar = true
    }

    /// The cover is gone: turn the page back, keeping it covered until upright.
    private func finishLeavingBar() {
        isLeavingBar = true
        barOrientation.portrait()
        Task {
            await waitForOrientation(landscape: false)
            isLeavingBar = false
        }
    }

    /// Waits for the window to take the turn it was asked for; `requestGeometryUpdate`
    /// has no completion, and the interface orientation lags the request by the animation.
    private func waitForOrientation(landscape: Bool) async {
        for _ in 0..<30 {
            let orientation = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?
                .interfaceOrientation
            if let orientation,
               orientation != .unknown,
               orientation.isLandscape == landscape
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Her weekly schedule as a play page of its own (spec #94): the chat's 「她的日程」 lands
/// here, with the calendar underneath it.
private struct SchedulePageView: View {
    let characterID: String?
    @State private var book = ScheduleDraftBook()

    var body: some View {
        ScheduleBoardView(initialCharacterID: characterID, book: $book)
    }
}
