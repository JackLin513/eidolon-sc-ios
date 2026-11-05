import Foundation
import XCTest
@testable import EidolonCore

final class MomentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_905_200) // 2026-11-05 20:00 Tokyo
    private let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .current

    private func installed() async throws -> (Eidolon, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Moments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root) }
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        return (eidolon, root)
    }

    private func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func addTurn(_ eidolon: Eidolon, character: String = "mano", at date: Date) async throws {
        try await eidolon.userQueue.write { db in
            let conversation = "conversation-\(character)"
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO conversations(id, character_id, created_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [conversation, character, Eidolon.timestamp(date)]
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, created_at)
                    VALUES (?, ?, 'user', 'こんばんは', ?)
                    """,
                arguments: [UUID().uuidString, conversation, Eidolon.timestamp(date)]
            )
        }
    }

    private func setAffinity(_ eidolon: Eidolon, _ value: Double, character: String = "mano") async throws {
        let stamp = Eidolon.timestamp(now)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, cooling, updated_at, gained_today, gained_on)
                    VALUES (?, ?, 0, ?, 0, NULL)
                    ON CONFLICT(character_id) DO UPDATE SET value = excluded.value,
                        cooling = 0, updated_at = excluded.updated_at
                    """,
                arguments: [character, value, stamp]
            )
        }
    }

    private func markPlanned(_ eidolon: Eidolon, at date: Date) async throws {
        let planned = day(date)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_state(id, planned_day) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET planned_day = excluded.planned_day
                    """,
                arguments: [planned]
            )
        }
    }

    private func insertPlan(
        _ eidolon: Eidolon, character: String = "mano", due: Date, kind: String = "daily",
        planDay: String? = nil
    ) async throws {
        let planned = planDay ?? day(now)
        let dueStamp = Eidolon.timestamp(due)
        let created = Eidolon.timestamp(now)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_plans(id, character_id, plan_day, due_at, kind, birthday, created_at)
                    VALUES (?, ?, ?, ?, ?, 0, ?)
                    """,
                arguments: [
                    UUID().uuidString, character, planned, dueStamp, kind, created,
                ]
            )
        }
    }

    private func insertPost(
        _ eidolon: Eidolon, character: String = "mano", revealAt: Date,
        ja: String = "今日もおつかれさま。"
    ) async throws -> String {
        let id = UUID().uuidString
        let planned = day(revealAt)
        let stamp = Eidolon.timestamp(revealAt)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_posts(id, character_id, ja, zh, plan_day, reveal_at, created_at)
                    VALUES (?, ?, ?, '今天也辛苦了。', ?, ?, ?)
                    """,
                arguments: [id, character, ja, planned, stamp, stamp]
            )
        }
        return id
    }

    private func settings(_ eidolon: Eidolon, enabled: Bool = true, posts: Int = 3) async throws {
        var value = MomentsSettings.default
        value.enabled = enabled
        value.dailyPosts = posts
        try await eidolon.setMomentsSettings(value)
    }

    func testAPlanBecomesAPostAndTheTurnIsLeftAlone() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        try await addTurn(eidolon, at: now)
        try await markPlanned(eidolon, at: now)
        try await insertPlan(eidolon, due: now.addingTimeInterval(-60))
        let provider = RecordingChatProvider(chunks: ["""
            <post><ja>事務所の窓から夕日が見えてる。</ja><zh>从办公室的窗户能看到夕阳。</zh></post>
            <likes>hiori</likes>
            <comment from="hiori"><ja>いいなあ。</ja><zh>真好啊。</zh></comment>
            """])

        let run = await eidolon.runMomentsDue(
            now: now, providers: MomentsProviders(chat: provider), seed: 7
        )
        XCTAssertEqual(run.generated, 1)
        let timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertEqual(timeline.count, 1)
        XCTAssertEqual(timeline.first?.characterID, "mano")
        XCTAssertTrue(timeline.first?.ja.contains("夕日") == true)
        let messages = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
        XCTAssertEqual(messages, 1, "a moment is not a turn")
        let moments = try await eidolon.serviceCalls().filter { $0.operation == .moment }
        XCTAssertEqual(moments.count, 1)
    }

    func testNothingHappensWhileTheSwitchIsOff() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon, enabled: false)
        try await addTurn(eidolon, at: now)
        try await insertPlan(eidolon, due: now.addingTimeInterval(-60))
        let provider = RecordingChatProvider(chunks: ["<post><ja>あ</ja><zh>啊</zh></post>"])
        let run = await eidolon.runMomentsDue(
            now: now, providers: MomentsProviders(chat: provider), seed: 1
        )
        XCTAssertEqual(run.generated, 0)
        let timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertTrue(timeline.isEmpty)
    }

    func testAColdCharacterDoesNotPost() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        try await addTurn(eidolon, at: now)
        try await setAffinity(eidolon, 5)
        try await insertPlan(eidolon, due: now.addingTimeInterval(-60))
        let provider = RecordingChatProvider(chunks: ["<post><ja>あ</ja><zh>啊</zh></post>"])
        _ = await eidolon.runMomentsDue(
            now: now, providers: MomentsProviders(chat: provider), seed: 1
        )
        let timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertTrue(timeline.isEmpty)
    }

    func testTheDailyLimitHoldsAcrossCharacters() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon, posts: 1)
        try await addTurn(eidolon, character: "mano", at: now)
        try await addTurn(eidolon, character: "hiori", at: now)
        try await markPlanned(eidolon, at: now)
        try await insertPlan(eidolon, character: "mano", due: now.addingTimeInterval(-60))
        try await insertPlan(eidolon, character: "hiori", due: now.addingTimeInterval(-60))
        let provider = RecordingChatProvider(chunks: [
            "<post><ja>一つ目。</ja><zh>第一条。</zh></post>",
            "<post><ja>二つ目。</ja><zh>第二条。</zh></post>",
        ])
        let run = await eidolon.runMomentsDue(
            now: now, providers: MomentsProviders(chat: provider), seed: 3
        )
        XCTAssertEqual(run.generated, 1)
        let timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertEqual(timeline.count, 1)
    }

    func testAReactionWaitsForItsRevealTime() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        let post = try await insertPost(eidolon, revealAt: now.addingTimeInterval(-3600))
        let reveal = Eidolon.timestamp(now.addingTimeInterval(600))
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_reactions(id, post_id, character_id, kind, ja, zh, position, reveal_at)
                    VALUES (?, ?, 'hiori', 'comment', 'いいね', '不错', 0, ?)
                    """,
                arguments: [UUID().uuidString, post, reveal]
            )
        }
        let timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertTrue(timeline.first?.reactions.isEmpty == true)
        let later = try await eidolon.momentsTimeline(now: now.addingTimeInterval(601))
        XCTAssertEqual(later.first?.reactions.count, 1)
    }

    func testTheProducerLikesOnceAndCommentsOnce() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        let post = try await insertPost(eidolon, revealAt: now.addingTimeInterval(-60))
        let liked = try await eidolon.likeMoment(post, now: now)
        XCTAssertTrue(liked)
        let likedAgain = try await eidolon.likeMoment(post, now: now)
        XCTAssertTrue(likedAgain)
        var timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertTrue(timeline.first?.liked == true)
        let unliked = try await eidolon.unlikeMoment(post)
        XCTAssertTrue(unliked)
        timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertFalse(timeline.first?.liked == true)

        let blank = try await eidolon.commentMoment(post, text: "   ", now: now)
        XCTAssertFalse(blank)
        let long = try await eidolon.commentMoment(
            post, text: String(repeating: "あ", count: 141), now: now
        )
        XCTAssertFalse(long)
        let first = try await eidolon.commentMoment(post, text: "かわいいね", now: now)
        XCTAssertTrue(first)
        let second = try await eidolon.commentMoment(post, text: "もう一度", now: now)
        XCTAssertFalse(second)
        timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertEqual(timeline.first?.comment?.text, "かわいいね")
        let deleted = try await eidolon.deleteMomentComment(post)
        XCTAssertTrue(deleted)
        timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertNil(timeline.first?.comment)
    }

    func testHerReplyComesOutWhenItsTimeHasCome() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        let post = try await insertPost(eidolon, revealAt: now.addingTimeInterval(-3600))
        let created = Eidolon.timestamp(now.addingTimeInterval(-1200))
        let reveal = Eidolon.timestamp(now.addingTimeInterval(-60))
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_comments(post_id, text, created_at, reply_reveal_at)
                    VALUES (?, 'かわいい', ?, ?)
                    """,
                arguments: [post, created, reveal]
            )
        }
        let provider = RecordingChatProvider(chunks: ["<ja>ありがとう。</ja><zh>谢谢。</zh>"])
        let run = await eidolon.runMomentsDue(
            now: now, providers: MomentsProviders(chat: provider), seed: 1
        )
        XCTAssertEqual(run.newReplies.count, 1)
        let timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertEqual(timeline.first?.comment?.revealedReply?.ja, "ありがとう。")
        let calls = try await eidolon.serviceCalls().filter { $0.operation == .momentReply }
        XCTAssertEqual(calls.count, 1)
    }

    func testAPostPastThirtyDaysGoesWithItsReactionsAndPicture() async throws {
        let (eidolon, root) = try await installed()
        try await settings(eidolon, enabled: false)
        let old = now.addingTimeInterval(-31 * 24 * 3600)
        let post = try await insertPost(eidolon, revealAt: old)
        let directory = root.appendingPathComponent("app/User/images/moments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("old.jpg")
        try Data("picture".utf8).write(to: file)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_images(id, post_id, file, width, height, composition, tag, note, created_at)
                    VALUES (?, ?, 'images/moments/old.jpg', 832, 1216, 'selfie', 'x', NULL, ?)
                    """,
                arguments: [UUID().uuidString, post, Eidolon.timestamp(old)]
            )
            try db.execute(
                sql: """
                    INSERT INTO moment_reactions(id, post_id, character_id, kind, ja, zh, position, reveal_at)
                    VALUES (?, ?, 'hiori', 'like', NULL, NULL, 0, ?)
                    """,
                arguments: [UUID().uuidString, post, Eidolon.timestamp(old)]
            )
        }
        try await eidolon.runMomentsDue(
            now: now, providers: MomentsProviders(chat: RecordingChatProvider(chunks: [""])), seed: 1
        )
        let timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let reactions = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM moment_reactions") ?? 0
        }
        XCTAssertEqual(reactions, 0)
    }

    func testTheBadgeAppearsAndClearsWhenThePageIsOpened() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        _ = try await insertPost(eidolon, revealAt: now.addingTimeInterval(-60))
        let badge = try await eidolon.momentsBadge(now: now)
        XCTAssertTrue(badge)
        try await eidolon.markMomentsOpened(now: now)
        let cleared = try await eidolon.momentsBadge(now: now)
        XCTAssertFalse(cleared)
    }

    func testThePlanForUnfinishedWorkWaits() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        try await addTurn(eidolon, at: now)
        try await markPlanned(eidolon, at: now)
        try await insertPlan(eidolon, due: now.addingTimeInterval(-60), kind: "work")
        let provider = RecordingChatProvider(chunks: ["<post><ja>あ</ja><zh>啊</zh></post>"])
        _ = await eidolon.runMomentsDue(
            now: now, providers: MomentsProviders(chat: provider), seed: 1
        )
        let timeline = try await eidolon.momentsTimeline(now: now)
        XCTAssertTrue(timeline.isEmpty)
        let plans = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM moment_plans") ?? 0
        }
        XCTAssertEqual(plans, 1, "the plan is pushed, not dropped")
    }
}

extension MomentTests {
    func testPlacesStayIndoorsWhenItIsRainingAndSkipRecentlyUsedOnes() async throws {
        let (eidolon, _) = try await installed()
        let character = try await eidolon.characters().first { $0.id == "mano" }!
        var random = SeededRandom(seed: "places")
        let wet = try await eidolon.momentPlaceCandidates(
            character: character, work: nil, now: now, todayLines: [], wet: true,
            random: &random
        )
        XCTAssertTrue(wet.allSatisfy { ["cafe", "books", "mall", "museum", "bath", "venue"]
            .contains($0.category.rawValue) })

        _ = try await insertPost(eidolon, revealAt: now.addingTimeInterval(-3600))
        let used = try await eidolon.momentRecentlyUsedPlaces(now: now)
        XCTAssertTrue(used.isEmpty, "a post without a place does not use one")
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "UPDATE moment_posts SET place_id = 'cafe', place_name = 'テストカフェ'"
            )
        }
        let after = try await eidolon.momentRecentlyUsedPlaces(now: now)
        XCTAssertTrue(after.contains("cafe"))
    }

    func testWeatherCodesFallIntoSevenKinds() {
        XCTAssertEqual(MomentWeather.Kind.from(wmo: 0), .clear)
        XCTAssertEqual(MomentWeather.Kind.from(wmo: 2), .partlyCloudy)
        XCTAssertEqual(MomentWeather.Kind.from(wmo: 3), .overcast)
        XCTAssertEqual(MomentWeather.Kind.from(wmo: 45), .fog)
        XCTAssertEqual(MomentWeather.Kind.from(wmo: 61), .rain)
        XCTAssertEqual(MomentWeather.Kind.from(wmo: 71), .snow)
        XCTAssertEqual(MomentWeather.Kind.from(wmo: 95), .thunder)
        XCTAssertTrue(MomentWeather.Kind.rain.isWet)
        XCTAssertFalse(MomentWeather.Kind.clear.isWet)
    }

    func testTheSevenCompositionsAskForTheRightShape() async throws {
        let (eidolon, _) = try await installed()
        let characters = try await eidolon.characters()
        let character = try XCTUnwrap(characters.first { $0.id == "mano" })
        let settings = ImageServiceSettings(apiKey: "x")

        let scenery = MomentImageDraft(
            composition: .scenery, place: ["park", "sunlight"], action: ["scenery"]
        )
        let sceneryRequest = await eidolon.momentImageRequest(
            scenery, character: character, characters: characters, settings: settings,
            adult: false
        )
        let landscape = try XCTUnwrap(sceneryRequest)
        XCTAssertTrue(landscape.prompt.hasPrefix("no humans"))
        XCTAssertTrue(landscape.negativePrompt.contains("1girl, 1boy, people"))
        XCTAssertEqual(landscape.width, 1216)
        XCTAssertEqual(landscape.height, 832)

        let selfie = MomentImageDraft(
            composition: .selfie, framing: .fullBody, place: ["office"], action: ["smile"]
        )
        let selfieRequest = await eidolon.momentImageRequest(
            selfie, character: character, characters: characters, settings: settings,
            adult: false
        )
        let portrait = try XCTUnwrap(selfieRequest)
        XCTAssertTrue(portrait.prompt.contains("selfie"))
        XCTAssertTrue(portrait.prompt.contains("upper body"), "a selfie cannot be full body")
        XCTAssertEqual(portrait.width, 832)
        XCTAssertEqual(portrait.characterPrompts.count, 1)

        let candid = MomentImageDraft(composition: .candid, action: ["laughing"])
        let candidRequest = await eidolon.momentImageRequest(
            candid, character: character, characters: characters, settings: settings,
            adult: false
        )
        let caught = try XCTUnwrap(candidRequest)
        XCTAssertTrue(caught.negativePrompt.contains("looking at viewer"))
        XCTAssertTrue(caught.prompt.contains("looking away"))

        let group = MomentImageDraft(
            composition: .group, with: ["hiori"], action: ["smile"]
        )
        let groupRequest = await eidolon.momentImageRequest(
            group, character: character, characters: characters, settings: settings,
            adult: false
        )
        let together = try XCTUnwrap(groupRequest)
        XCTAssertTrue(together.prompt.hasPrefix("2girls"))
        XCTAssertEqual(together.characterPrompts.count, 2)
        XCTAssertEqual(together.width, 1216)

        let nobody = MomentImageDraft(composition: .group, with: ["nobody"])
        let missing = await eidolon.momentImageRequest(
            nobody, character: character, characters: characters, settings: settings,
            adult: false
        )
        XCTAssertNil(missing)
    }

    func testTheProducerIsToldAboutHerRecentPostsOnlyWhenThereAreAny() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon, enabled: false)
        let emptyOff = try await eidolon.momentPromptLines(
            characterID: "mano", now: now, timeZone: tokyo
        )
        XCTAssertTrue(emptyOff.isEmpty)

        try await settings(eidolon)
        let post = try await insertPost(eidolon, revealAt: now.addingTimeInterval(-3600))
        let stamp = Eidolon.timestamp(now)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "INSERT INTO moment_likes(post_id, created_at) VALUES (?, ?)",
                arguments: [post, stamp]
            )
            try db.execute(
                sql: """
                    INSERT INTO moment_comments(post_id, text, created_at, reply_reveal_at, reply_ja, reply_zh, reply_at)
                    VALUES (?, 'かわいい', ?, ?, 'ありがとう', '谢谢', ?)
                    """,
                arguments: [post, stamp, stamp, stamp]
            )
        }
        let lines = try await eidolon.momentPromptLines(
            characterID: "mano", now: now, timeZone: tokyo
        )
        XCTAssertEqual(lines.first, "# 你最近发的朋友圈")
        XCTAssertTrue(lines.joined().contains("制作人赞了"))
        XCTAssertTrue(lines.joined().contains("你回了「ありがとう」"))
        XCTAssertTrue(lines.last?.contains("不要抱怨") == true)
    }

    func testACommentFromACloseCharacterSchedulesAnEarlyReply() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        try await setAffinity(eidolon, 90)
        let post = try await insertPost(eidolon, revealAt: now.addingTimeInterval(-60))
        let left = try await eidolon.commentMoment(post, text: "かわいいね", now: now, seed: 5)
        XCTAssertTrue(left)
        let reveal: String? = try await eidolon.userQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT reply_reveal_at FROM moment_comments WHERE post_id = ?",
                arguments: [post]
            )
        }
        let date = try XCTUnwrap(reveal.flatMap(Eidolon.parseTimestamp))
        let minutes = date.timeIntervalSince(now) / 60
        XCTAssertGreaterThanOrEqual(minutes, 5)
        XCTAssertLessThanOrEqual(minutes, 30)
    }

    func testTheStatsPageCountsMoments() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        let post = try await insertPost(eidolon, revealAt: now.addingTimeInterval(-60))
        try await eidolon.likeMoment(post, now: now)
        _ = try await eidolon.commentMoment(post, text: "かわいい", now: now)
        let summary = try await eidolon.statsSummary(range: .all, now: now, timeZone: tokyo)
        XCTAssertEqual(summary.moments.posts, 1)
        XCTAssertEqual(summary.moments.likedPosts, 1)
        XCTAssertEqual(summary.moments.commentedPosts, 1)
        XCTAssertTrue(summary.moments.hasAny)
    }
}

extension MomentTests {
    func testAPostAnswerParsesItsPostsPlaceLikesCommentsAndImage() throws {
        let raw = """
            <post><ja>今日は少し早めに上がれたので、新宿で一息ついてます。</ja><zh>今天收工早，在新宿歇一会儿。</zh></post>
            <place>coffee-seibu-shinjuku</place>
            <likes>hiori, meguru</likes>
            <comment from="hiori"><ja>いい店だね。</ja><zh>不错的店。</zh></comment>
            <image>
            composition: food
            shot: other
            framing: upper body
            place: cafe, indoors, window, sunlight
            action: pudding, coffee
            note: 桌上的布丁和咖啡
            </image>
            """
        let draft = try XCTUnwrap(Eidolon.parseMomentDraft(raw))
        XCTAssertEqual(draft.placeID, "coffee-seibu-shinjuku")
        XCTAssertEqual(draft.likes, ["hiori", "meguru"])
        XCTAssertEqual(draft.comments.first?.from, "hiori")
        XCTAssertEqual(draft.comments.first?.zh, "不错的店。")
        XCTAssertEqual(draft.image?.composition, .food)
        XCTAssertEqual(draft.image?.action, ["pudding", "coffee"])

        XCTAssertNil(Eidolon.parseMomentDraft("<post><ja>あ</ja></post>"))
    }

    func testAnImageBlockWithoutACompositionIsNotDrawn() throws {
        let draft = MomentImageDraft(text: """
            shot: other
            framing: upper body
            action: smile
            """)
        XCTAssertNil(draft)
        let parsed = try XCTUnwrap(MomentImageDraft(text: """
            composition: 自拍
            framing: 全身
            action: smile, peace sign
            """))
        XCTAssertEqual(parsed.composition, .selfie)
        XCTAssertEqual(parsed.framing, .fullBody)
        XCTAssertEqual(parsed.action, ["smile", "peace sign"])
    }
}

extension MomentTests {
    func testTurningItBackOnTodayPlansTheRestOfTheDay() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon, enabled: false)
        try await markPlanned(eidolon, at: now)
        try await settings(eidolon, enabled: true)
        let planned = try await eidolon.userQueue.read { db in
            try String.fetchOne(db, sql: "SELECT planned_day FROM moment_state WHERE id = 1")
        }
        XCTAssertNil(planned, "a switch turned back on today plans again")
    }

    func testPostsOnTheSameDayKeepAnHourApart() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon, posts: 10)
        for id in ["mano", "hiori"] {
            try await addTurn(eidolon, character: id, at: now)
        }
        let existing = now.addingTimeInterval(-60 * 60)
        _ = try await insertPost(eidolon, revealAt: existing)
        let value = try await eidolon.momentsSettings()
        var total = 0
        for seed in 0..<12 {
            try await eidolon.userQueue.write { db in
                try db.execute(sql: "DELETE FROM moment_plans")
                try db.execute(sql: "UPDATE moment_state SET planned_day = NULL")
            }
            var random = SeededRandom(seed: "\(seed)")
            try await eidolon.ensureMomentsPlans(now: now, settings: value, random: &random)
            let dues = try await eidolon.userQueue.read { db in
                try String.fetchAll(db, sql: "SELECT due_at FROM moment_plans")
            }
            let dates = dues.compactMap(Eidolon.parseTimestamp)
            total += dates.count
            for date in dates {
                XCTAssertGreaterThanOrEqual(
                    abs(date.timeIntervalSince(existing)), 3600,
                    "a new plan keeps an hour clear of the post already out"
                )
            }
            for (index, date) in dates.enumerated() {
                for other in dates[(index + 1)...] {
                    XCTAssertGreaterThanOrEqual(abs(date.timeIntervalSince(other)), 3600)
                }
            }
        }
        XCTAssertGreaterThan(total, 0)
    }

    func testAGroupPictureBringsItsMembersIntoTheLikes() async throws {
        let (eidolon, _) = try await installed()
        let characters = try await eidolon.characters()
        let circle = characters.filter { $0.id != "mano" }
        let post = try await insertPost(eidolon, revealAt: now)
        let draft = Eidolon.MomentDraft(
            ja: "みんなで撮った。", zh: "大家一起拍的。", placeID: nil, likes: [],
            comments: [("hiori", "楽しいね。", "真开心。")],
            image: MomentImageDraft(
                composition: .group, framing: .wideShot, with: ["hiori"],
                place: ["studio"], action: ["smile"], note: "合照"
            )
        )
        var random = SeededRandom(seed: "1")
        await eidolon.insertMomentReactions(
            postID: post, draft: draft, circle: circle, birthday: false,
            now: now, random: &random
        )
        let likers = try await eidolon.userQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT character_id FROM moment_reactions WHERE post_id = ? AND kind = 'like'",
                arguments: [post]
            )
        }
        let comments = try await eidolon.userQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT character_id FROM moment_reactions WHERE post_id = ? AND kind = 'comment'",
                arguments: [post]
            )
        }
        XCTAssertEqual(likers, ["hiori"], "whoever is in the picture likes it")
        XCTAssertTrue(comments.isEmpty, "one person does not both like and comment")
    }

    func testAStatsPageShowsMomentsWhileTheSwitchIsOn() async throws {
        let (eidolon, _) = try await installed()
        try await settings(eidolon)
        let summary = try await eidolon.statsSummary(range: .thirtyDays, now: now, timeZone: tokyo)
        XCTAssertTrue(summary.moments.enabled)
        XCTAssertTrue(summary.moments.hasAny)
        XCTAssertEqual(summary.moments.posts, 0)
    }

    func testWideShotFramingParsesForMoments() throws {
        let draft = try XCTUnwrap(MomentImageDraft(text: """
            composition: 风景
            framing: 远景
            action: night street
            """))
        XCTAssertEqual(draft.framing, .wideShot)
    }
}
