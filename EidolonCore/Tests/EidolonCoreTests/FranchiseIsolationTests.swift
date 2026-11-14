import Foundation
import Testing
@testable import EidolonCore

/// Phase B 的验收锚点（ADR-0037 / #147）：两个企划可以有相同 local id，但用户数据必须隔离。
///
/// 这个测试现在应该失败。它描述的是 v25 复合身份完成后的行为，不是当前实现的镜像。
@Suite("Franchise isolation")
struct FranchiseIsolationTests {
    private func makeEidolon() throws -> (Eidolon, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "eidolon-isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try Eidolon(location: .init(root: root)), root)
    }

    /// 安装两个都含 local id `mano` 的合成内容包：默认的 shiny，以及 totsulover。
    private func installTwoFranchises(on eidolon: Eidolon, in root: URL) async throws {
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))

        var options = Fixture.Options()
        options.franchise = "totsulover"
        options.contentSetID = "totsulover.isolation"
        let otherRoot = root.appending(path: "totsulover-src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let otherBundle = try Fixture.makeBundle(in: otherRoot, options: options)
        try await eidolon.installContent(bundleAt: otherBundle, franchise: "totsulover")
    }

    @Test("the same local character id in two franchises does not share a conversation")
    func sameLocalCharacterIDDoesNotShareAConversation() async throws {
        let (eidolon, root) = try makeEidolon()
        try await installTwoFranchises(on: eidolon, in: root)

        // 在 shiny 里开始一段对话。
        #expect(await eidolon.activeFranchise == "shiny")
        let shinyConversation = try await eidolon.startConversation(characterID: "mano")

        // 切到另一个企划后，同一个 local id 应该是另一个角色。
        try await eidolon.activateContent(franchise: "totsulover")

        let totsuloverConversation = try await eidolon.startConversation(characterID: "mano")
        #expect(
            totsuloverConversation != shinyConversation,
            "两个企划的 mano 不能续到同一个会话"
        )

        let current = try await eidolon.currentConversation(characterID: "mano")
        #expect(
            current?.id == totsuloverConversation,
            "切包后当前会话必须属于 totsulover 的 mano"
        )
    }

    @Test("each franchise keeps its own current conversation and history")
    func eachFranchiseKeepsItsOwnCurrentConversation() async throws {
        let (eidolon, root) = try makeEidolon()
        try await installTwoFranchises(on: eidolon, in: root)

        let shinyConversation = try await eidolon.startConversation(characterID: "mano")
        try await eidolon.activateContent(franchise: "totsulover")
        let totsuloverConversation = try await eidolon.startConversation(characterID: "mano")

        let totsuloverHistory = try await eidolon.conversations(characterID: "mano")
        #expect(totsuloverHistory.count == 1)
        #expect(totsuloverHistory.first?.id == totsuloverConversation)

        try await eidolon.activateContent(franchise: "shiny")
        #expect(
            try await eidolon.currentConversationID("mano") == shinyConversation,
            "切回 shiny 后应恢复 shiny 的当前会话"
        )
        let shinyHistory = try await eidolon.conversations(characterID: "mano")
        #expect(shinyHistory.count == 1)
        #expect(shinyHistory.first?.id == shinyConversation)
    }
    @Test("affinity is kept per franchise, not shared by the same local id")
    func affinityIsScopedToItsFranchise() async throws {
        let (eidolon, root) = try makeEidolon()
        try await installTwoFranchises(on: eidolon, in: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await eidolon.userQueue.write { db in
            try Eidolon.writeAffinity(
                db, franchiseID: "shiny", characterID: "mano", value: 30,
                cooling: false, updatedAt: Eidolon.timestamp(now),
                gainedToday: 0, gainedOn: nil
            )
        }
        let shinyValue = try await eidolon.userQueue.read { db in
            try Eidolon.readAffinity(
                db, franchiseID: "shiny", characterID: "mano", now: now
            ).value
        }
        #expect(shinyValue == 30)

        try await eidolon.activateContent(franchise: "totsulover")
        let totsuloverValueBefore = try await eidolon.userQueue.read { db in
            try Eidolon.readAffinity(
                db, franchiseID: "totsulover", characterID: "mano", now: now
            ).value
        }
        #expect(
            totsuloverValueBefore == AffinityRules.normal,
            "totsulover 的 mano 不能继承 shiny 的亲密度"
        )

        try await eidolon.userQueue.write { db in
            try Eidolon.writeAffinity(
                db, franchiseID: "totsulover", characterID: "mano", value: 60,
                cooling: false, updatedAt: Eidolon.timestamp(now),
                gainedToday: 0, gainedOn: nil
            )
        }
        let totsuloverValue = try await eidolon.userQueue.read { db in
            try Eidolon.readAffinity(
                db, franchiseID: "totsulover", characterID: "mano", now: now
            ).value
        }
        #expect(totsuloverValue == 60)

        try await eidolon.activateContent(franchise: "shiny")
        let shinyValueAgain = try await eidolon.userQueue.read { db in
            try Eidolon.readAffinity(
                db, franchiseID: "shiny", characterID: "mano", now: now
            ).value
        }
        #expect(shinyValueAgain == 30, "切回 shiny 必须读回 shiny 的亲密度")
    }

    @Test("each franchise lists only its own conversations")
    func conversationListIsScopedToItsFranchise() async throws {
        let (eidolon, root) = try makeEidolon()
        try await installTwoFranchises(on: eidolon, in: root)

        let shinyConversation = try await eidolon.startConversation(characterID: "mano")
        try await eidolon.activateContent(franchise: "totsulover")
        let totsuloverConversation = try await eidolon.startConversation(characterID: "mano")

        let totsuloverList = try await eidolon.conversations(characterID: "mano")
        #expect(totsuloverList.map(\.id) == [totsuloverConversation])
        #expect(!totsuloverList.contains { $0.id == shinyConversation })

        try await eidolon.activateContent(franchise: "shiny")
        let shinyList = try await eidolon.conversations(characterID: "mano")
        #expect(shinyList.map(\.id) == [shinyConversation])
        #expect(!shinyList.contains { $0.id == totsuloverConversation })
    }

    @Test("cycle seed and records are kept per franchise")
    func cycleIsScopedToItsFranchise() async throws {
        let (eidolon, root) = try makeEidolon()
        try await installTwoFranchises(on: eidolon, in: root)
        let today = CalendarDay(year: 2026, month: 11, day: 14)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let shinySeed = try #require(try await eidolon.cycleSeed(characterID: "mano"))
        try await eidolon.addCycleRecord(
            characterID: "mano", firstDay: today, days: 5, now: now, timeZone: .gmt
        )
        #expect(try await eidolon.cycleRecords(characterID: "mano").count == 1)

        try await eidolon.activateContent(franchise: "totsulover")
        let totsuloverSeed = try #require(try await eidolon.cycleSeed(characterID: "mano"))
        #expect(totsuloverSeed != shinySeed, "两个企划的同名角色不能共用一个周期种子")
        #expect(try await eidolon.cycleRecords(characterID: "mano").isEmpty)

        try await eidolon.addCycleRecord(
            characterID: "mano", firstDay: today, days: 6, now: now, timeZone: .gmt
        )
        #expect(try await eidolon.cycleRecords(characterID: "mano").count == 1)

        try await eidolon.activateContent(franchise: "shiny")
        let shinyRecords = try await eidolon.cycleRecords(characterID: "mano")
        #expect(shinyRecords.count == 1)
        #expect(shinyRecords[0].days == 5)
    }

    @Test("saved schedule placements are read per franchise")
    func scheduleIsScopedToItsFranchise() async throws {
        let (eidolon, root) = try makeEidolon()
        try await installTwoFranchises(on: eidolon, in: root)
        let week = CalendarDay(year: 2026, month: 11, day: 14)
        let jobID = "\(week.stamp):vocal"

        for franchise in ["shiny", "totsulover"] {
            try await eidolon.userQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO weekly_jobs(
                            id, franchise_id, week, character_id, listed_id, name, note,
                            category, length, slots
                        ) VALUES (?, ?, ?, 'mano', 'vocal', ?, '说明。', 'practice', 1, NULL)
                        """,
                    arguments: [jobID, franchise, week.stamp, "声乐课-\(franchise)"]
                )
                try db.execute(
                    sql: """
                        INSERT INTO schedule_placements(
                            franchise_id, week, job_id, character_id, day, slot, saved_at
                        ) VALUES (?, ?, ?, 'mano', 0, 0, '2026-11-14T00:00:00.000000Z')
                        """,
                    arguments: [franchise, week.stamp, jobID]
                )
            }
        }

        #expect(try await eidolon.savedPlacements().map(\.job.name) == ["声乐课-shiny"])
        try await eidolon.activateContent(franchise: "totsulover")
        #expect(try await eidolon.savedPlacements().map(\.job.name) == ["声乐课-totsulover"])
    }

    @Test("the producer profile is read and written per franchise")
    func producerProfileIsScopedToItsFranchise() async throws {
        let (eidolon, root) = try makeEidolon()
        try await installTwoFranchises(on: eidolon, in: root)

        try await eidolon.updateProducerProfile(
            ProducerProfile(formOfAddress: "槐くん", gender: .male)
        )
        #expect(try await eidolon.producerProfile().formOfAddress == "槐くん")

        try await eidolon.activateContent(franchise: "totsulover")
        #expect(try await eidolon.producerProfile() == .default)

        try await eidolon.updateProducerProfile(
            ProducerProfile(formOfAddress: "槐さん", gender: .male)
        )
        #expect(try await eidolon.producerProfile().formOfAddress == "槐さん")

        try await eidolon.activateContent(franchise: "shiny")
        #expect(try await eidolon.producerProfile().formOfAddress == "槐くん")
    }

}
