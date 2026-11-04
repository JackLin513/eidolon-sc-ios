import EidolonCore
import SwiftUI

/// Her four achievements with the producer, and 集齐 (spec #69).
struct HerAchievementsView: View {
    let characterID: String
    let characterName: String
    @Environment(AppModel.self) private var app
    @State private var hers: HerAchievements?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        List {
            if let hers {
                Section {
                    ForEach(hers.achievements) { achievement in
                        AchievementRowView(progress: achievement)
                    }
                } header: {
                    Text("和\(characterName)")
                } footer: {
                    Text("第 n 个阶段到账 n 次抽奖；四个成就全部解锁算集齐。")
                }
                Section {
                    completeRow(hers)
                } header: {
                    Text("集齐")
                }
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "成就暂时打不开",
                    systemImage: "trophy",
                    description: Text(errorMessage ?? "稍后再试。")
                )
            }
        }
        .navigationTitle("\(characterName)的成就")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            // Seen here, so the dots go without leaving the page.
            await app.markAchievementsSeen(characterID: characterID)
            await load()
        }
        .refreshable { await load() }
    }

    private func completeRow(_ hers: HerAchievements) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rosette")
                .foregroundStyle(hers.isComplete ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(hers.isComplete ? "集齐了" : "集齐")
                    .font(.body)
                Text(hers.isComplete ? "重置卡 ×1 已到账" : "重置卡 ×1")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hers.isNew { newDot }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("achievement.complete")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            hers = try await app.herAchievements(characterID: characterID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The four achievements of everyone together (spec #70).
struct AllAchievementsView: View {
    @Environment(AppModel.self) private var app
    @State private var all: AllAchievements?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        List {
            if let all {
                Section {
                    ForEach(all.achievements) { achievement in
                        AchievementRowView(progress: achievement)
                    }
                } header: {
                    Text("和她们一起")
                } footer: {
                    Text("往来过的角色、到过亲密的角色、来过的天数和抽过的奖，从每个人的进度合起来算。")
                }
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "成就暂时打不开",
                    systemImage: "trophy",
                    description: Text(errorMessage ?? "稍后再试。")
                )
            }
        }
        .navigationTitle("成就")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            await app.markAchievementsSeen(characterID: nil)
            // The achievements page is one of the two pages that clear the play tab's dot.
            await app.markPlaySeen()
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            all = try await app.allAchievements()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One achievement's row: its progress, stage points, and what the next stage gives.
struct AchievementRowView: View {
    let progress: AchievementProgress

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(progress.title)
                        .font(.body)
                    if progress.isNew { newDot }
                }
                HStack(spacing: 6) {
                    Text(progress.progressText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let goal = progress.nextGoalText {
                        Text("→ \(goal)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("全部解锁")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                stageDots
            }
            Spacer(minLength: 0)
            if let next = progress.next {
                Label("+\(next.draws) 抽", systemImage: "dice")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(progress.title)，\(progress.progressText)，"
                + "已解锁 \(progress.unlockedCount) 个阶段"
                + (progress.next.map { "，下一阶段 \(progress.nextGoalText ?? "")，抽奖 +\($0.draws)" }
                    ?? "，全部解锁")
                + (progress.isNew ? "，有新解锁" : "")
        )
        .accessibilityIdentifier("achievement.\(progress.id.rawValue)")
    }

    private var stageDots: some View {
        HStack(spacing: 5) {
            ForEach(progress.stages) { stage in
                Circle()
                    .fill(stage.unlockedAt == nil ? Color(.tertiarySystemFill) : Color.accentColor)
                    .frame(width: 7, height: 7)
                    .overlay {
                        if stage.isNew {
                            Circle()
                                .strokeBorder(Color.red, lineWidth: 1.5)
                                .frame(width: 11, height: 11)
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(true)
    }
}

private var newDot: some View {
    Circle()
        .fill(Color.red)
        .frame(width: 7, height: 7)
        .accessibilityLabel("新解锁")
}
