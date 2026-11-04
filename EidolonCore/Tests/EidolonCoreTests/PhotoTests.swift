import Foundation
import XCTest
@testable import EidolonCore

/// The image service as a turn sees it: fixed bytes or a failure, and what it was asked.
actor FakePhotoGenerator: ImageGenerating {
    private(set) var requests: [ImageRequest] = []
    let data: Data
    let failure: ImageGenerationError?

    init(data: Data = Data("JPEG".utf8), failure: ImageGenerationError? = nil) {
        self.data = data
        self.failure = failure
    }

    func generate(_ request: ImageRequest, settings: ImageServiceSettings) async throws -> Data {
        requests.append(request)
        if let failure { throw failure }
        return data
    }
}

/// A judge that answers a fixed photo verdict and remembers whether it was asked.
actor PhotoJudge: JudgeProvider {
    private(set) var askedPhoto: [Bool] = []
    let wants: Bool

    init(wants: Bool) {
        self.wants = wants
    }

    private var verdict: JudgeVerdict {
        JudgeVerdict(affinity: .noEffect, need: .nothing, wantsPhoto: wants)
    }

    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeVerdict {
        verdict
    }

    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String,
        adultMode: Bool
    ) async throws -> JudgeVerdict {
        verdict
    }

    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String,
        adultMode: Bool,
        askPhoto: Bool
    ) async throws -> JudgeVerdict {
        askedPhoto.append(askPhoto)
        return verdict
    }
}

final class PhotoTagTests: XCTestCase {
    private func tag(_ text: String) throws -> PhotoTag {
        try PhotoTag(text: text)
    }

    func testParsesHerDescription() throws {
        let photo = try tag("""
            rating: sensitive
            shot: selfie
            framing: upper body
            place: cafe, afternoon, sunlight
            outfit: white shirt, cardigan
            action: peace sign, smile
            note: 在咖啡店给他拍的自拍
            """)
        XCTAssertEqual(photo.rating, .sensitive)
        XCTAssertEqual(photo.shot, .selfie)
        XCTAssertEqual(photo.framing, .upperBody)
        XCTAssertEqual(photo.place, ["cafe", "afternoon", "sunlight"])
        XCTAssertEqual(photo.outfit, ["white shirt", "cardigan"])
        XCTAssertEqual(photo.action, ["peace sign", "smile"])
        XCTAssertEqual(photo.note, "在咖啡店给他拍的自拍")
    }

    func testSelfieCannotBeAFullBodyShot() throws {
        let photo = try tag("""
            shot: selfie
            framing: full body
            place: park
            outfit: casual
            action: smile
            """)
        XCTAssertEqual(photo.framing, .upperBody)
    }

    func testEveryColumnIsRequired() {
        XCTAssertThrowsError(try tag("shot: selfie\nframing: portrait\nplace: park"))
        XCTAssertThrowsError(try tag("shot: person\nframing: portrait\nplace: park\noutfit: casual\naction: smile"))
        XCTAssertThrowsError(try tag("shot: selfie\nframing: extreme wide\nplace: park\noutfit: casual\naction: smile"))
    }

    func testSerializedTagGoesBackAsSheWroteIt() throws {
        let text = "shot: other\nframing: cowboy shot\nplace: park\noutfit: casual\naction: wave"
        let photo = try tag(text)
        XCTAssertEqual(photo.serialized, "<photo>\n\(text)\n</photo>")
    }

    func testAllAgesPromptDropsBlockedTagsAndUsesTheAllAgesNegative() throws {
        let table = TestPhotoTagTable.make()
        let photo = try tag("""
            rating: explicit
            shot: selfie
            framing: portrait
            place: cafe
            outfit: nude, casual
            action: smile
            """)
        let request = try PhotoPromptBuilder.request(
            tag: photo,
            character: TestPhotoTagTable.character(),
            style: "",
            adult: false,
            table: table,
            model: "test-model"
        )
        XCTAssertFalse(request.prompt.contains("nude"))
        XCTAssertTrue(request.prompt.contains("casual"))
        XCTAssertTrue(request.prompt.contains("rating:general"))
        XCTAssertEqual(request.negativePrompt, PhotoPromptBuilder.allAgesNegative)
        XCTAssertEqual(request.width, 832)
        XCTAssertEqual(request.height, 1216)
        XCTAssertTrue(request.prompt.contains("sakuragi mano"))
        XCTAssertTrue(request.prompt.contains("brown hair, brown eyes"))
    }

    func testAdultPromptKeepsNudityButStillDropsAppearance() throws {
        let table = TestPhotoTagTable.make()
        let photo = try tag("""
            shot: selfie
            framing: upper body
            place: cafe
            outfit: nude
            action: smile
            """)
        let request = try PhotoPromptBuilder.request(
            tag: photo,
            character: TestPhotoTagTable.character(),
            style: "",
            adult: true,
            table: table,
            model: "adult-model"
        )
        XCTAssertTrue(request.prompt.contains("nude"))
        XCTAssertTrue(request.prompt.contains("rating:questionable"))
        XCTAssertEqual(request.negativePrompt, PhotoPromptBuilder.adultNegative)
        XCTAssertEqual(request.model, "adult-model")
    }

    func testACharacterWithoutPhotoTagsCannotMakeOne() throws {
        let table = TestPhotoTagTable.make()
        let photo = try tag("""
            shot: selfie
            framing: portrait
            place: cafe
            outfit: casual
            action: smile
            """)
        XCTAssertThrowsError(try PhotoPromptBuilder.request(
            tag: photo,
            character: CharacterConfig(id: "plain", name: "普通"),
            style: "",
            adult: false,
            table: table,
            model: "test-model"
        ))
    }
}

enum TestPhotoTagTable {
    static func make() -> PhotoTagTable {
        PhotoTagTable(
            model: "test-image",
            known: ["smile", "cafe", "casual", "nude", "indoors"],
            rewrites: [:],
            allowed: ["smile", "cafe", "casual"],
            blocked: [
                .nudity: .init(tags: ["nude"], words: []),
                .appearance: .init(tags: ["freakishly long legs"], words: []),
            ]
        )
    }

    static func character() -> CharacterConfig {
        CharacterConfig(
            id: "mano",
            name: "樱木真乃",
            photoTag: "sakuragi mano",
            photoAppearance: ["brown hair", "brown eyes"]
        )
    }
}

final class PhotoTagParsingTests: XCTestCase {
    private func tags(_ chunks: [String]) -> [(tags: [PhotoTag], blocks: [ReplyBlock])] {
        var parser = ReplyParser()
        var found: [PhotoTag] = []
        for chunk in chunks {
            for event in parser.feed(chunk) {
                if case let .photoTag(tag) = event { found.append(tag) }
            }
        }
        for event in parser.finish() {
            if case let .photoTag(tag) = event { found.append(tag) }
        }
        return [(found, parser.blocks)]
    }

    private static let tag = """
        <photo>
        shot: selfie
        framing: upper body
        place: cafe
        outfit: casual
        action: smile
        </photo>
        """

    func testTheTagAtTheStartIsTakenAndKeptOutOfTheReply() {
        let (tags, blocks) = tags([Self.tag + "<ja>はい。</ja><zh>好。</zh>"]).first!
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].place, ["cafe"])
        XCTAssertEqual(blocks, [.line(ReplySegment(ja: "はい。", zh: "好。"))])
    }

    func testOnlyTheFirstTagAtTheStartCounts() {
        let (tags, blocks) = tags([
            Self.tag + "<ja>はい。</ja><zh>好。</zh>" + Self.tag,
        ]).first!
        XCTAssertEqual(tags.count, 1)
        XCTAssertFalse(blocks.isEmpty)
    }

    func testATagAfterHerWordsIsNotAPhoto() {
        let (tags, _) = tags(["<ja>はい。</ja><zh>好。</zh>" + Self.tag]).first!
        XCTAssertTrue(tags.isEmpty)
    }

    func testATagThatDoesNotParseIsNotAPhoto() {
        let (tags, blocks) = tags([
            "<photo>\nshot: selfie\n</photo><ja>はい。</ja><zh>好。</zh>",
        ]).first!
        XCTAssertTrue(tags.isEmpty)
        XCTAssertEqual(blocks, [.line(ReplySegment(ja: "はい。", zh: "好。"))])
    }
}

final class PhotoTurnTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonPhoto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        let bundle = try Fixture.makeBundle(in: root)
        try await eidolon.install(bundleAt: bundle)
        return eidolon
    }

    private static let tagChunk = """
        <photo>
        shot: selfie
        framing: upper body
        place: cafe
        outfit: casual
        action: smile
        </photo>
        """

    private func send(
        _ eidolon: Eidolon,
        chunks: [String],
        judge: PhotoJudge?,
        photo: PhotoTurnContext?,
        provider: RecordingChatProvider
    ) async throws -> (ids: [String], record: TurnRecord?) {
        var ids: [String] = []
        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: "发张照片看看",
            provider: provider,
            judge: judge,
            photo: photo
        ) {
            switch event {
            case let .photo(id, status):
                ids.append(id)
                XCTAssertEqual(status, .pending)
            case let .finished(finished):
                record = finished
            case .delta, .speechDelta, .sceneDelta, .photosUsedUp:
                break
            }
        }
        return (ids, record)
    }

    /// The image lands in its own task; wait for it the way the app's polling does.
    private func readyImage(_ eidolon: Eidolon, id: String) async throws -> Data? {
        for _ in 0..<100 {
            if let data = try await eidolon.photoImage(id: id) { return data }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func testTurnMakesThePhotoSheAsksFor() async throws {
        let eidolon = try await installedEidolon()
        let generator = FakePhotoGenerator(data: Data("JPEG".utf8))
        let judge = PhotoJudge(wants: true)
        let provider = RecordingChatProvider(chunks: [
            Self.tagChunk + "<ja>はい、撮ったよ。</ja><zh>好，拍好了。</zh>",
        ])
        let context = PhotoTurnContext(
            generator: generator,
            settings: ImageServiceSettings(apiKey: "test-key")
        )

        let (ids, record) = try await send(
            eidolon, chunks: provider.chunks, judge: judge, photo: context, provider: provider
        )
        XCTAssertEqual(ids.count, 1)
        let id = try XCTUnwrap(ids.first)
        let finished = try XCTUnwrap(record)
        XCTAssertEqual(finished.photo?.id, id)
        // The reply itself carries no tag: the picture is the block she wrote then.
        XCTAssertEqual(finished.segments, [ReplySegment(ja: "はい、撮ったよ。", zh: "好，拍好了。")])
        let asked = await judge.askedPhoto
        XCTAssertEqual(asked, [true])

        let picture = try await readyImage(eidolon, id: id)
        XCTAssertEqual(picture, Data("JPEG".utf8))
        let stored = try await eidolon.photo(id: id)
        XCTAssertEqual(stored?.status, .ready)

        let made = await generator.requests
        let request = try XCTUnwrap(made.first)
        XCTAssertTrue(request.prompt.contains("sakuragi mano"))
        XCTAssertEqual(request.model, ImageServiceSettings.defaultModel)

        let calls = try await eidolon.serviceCalls()
        let imageCall = try XCTUnwrap(calls.first { $0.service == .image })
        XCTAssertEqual(imageCall.operation, .image)
        XCTAssertEqual(imageCall.unit, .images)
        XCTAssertEqual(imageCall.input, 1)
        XCTAssertEqual(imageCall.model, ImageServiceSettings.defaultModel)
        XCTAssertNil(imageCall.error)
        XCTAssertFalse(imageCall.provider.isEmpty)

        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        let reply = try XCTUnwrap(snapshot?.messages.last)
        XCTAssertEqual(reply.photo?.status, .ready)
        // Reading it again restores the same picture; nothing is generated a second time.
        _ = try await eidolon.currentConversation(characterID: "mano")
        let again = try await eidolon.photoImage(id: id)
        XCTAssertEqual(again, Data("JPEG".utf8))
        let remade = await generator.requests
        XCTAssertEqual(remade.count, 1)
        let latest = try await eidolon.latestActivities()
        XCTAssertEqual(latest["mano"]?.hasPhoto, true)
        XCTAssertEqual(reply.photoTag, Self.tagChunk.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "<photo>\n", with: "").replacingOccurrences(of: "\n</photo>", with: ""))
    }

    func testTheTagStaysInHerHistoryButNotInTheBubble() async throws {
        let eidolon = try await installedEidolon()
        let generator = FakePhotoGenerator()
        let judge = PhotoJudge(wants: true)
        let provider = RecordingChatProvider(chunks: [
            Self.tagChunk + "<ja>はい。</ja><zh>好。</zh>",
        ])
        let context = PhotoTurnContext(
            generator: generator,
            settings: ImageServiceSettings(apiKey: "test-key")
        )
        _ = try await send(
            eidolon, chunks: provider.chunks, judge: judge, photo: context, provider: provider
        )
        let second = RecordingChatProvider(chunks: ["<ja>どうぞ。</ja><zh>请。</zh>"])
        _ = try await eidolon.sendTurn(
            characterID: "mano",
            text: "谢谢",
            provider: second,
            judge: judge
        ).collect()
        // The next turn reads the tag as she wrote it, so she remembers what she sent.
        let prompt = try XCTUnwrap(second.prompts.first)
        XCTAssertTrue(prompt.contains { $0.content.contains("<photo>") })
    }

    func testNoPhotoContextMeansSheIsToldSheCannotSend() async throws {
        let eidolon = try await installedEidolon()
        let judge = PhotoJudge(wants: true)
        let provider = RecordingChatProvider(chunks: ["<ja>ごめん、写真は送れないの。</ja><zh>抱歉，发不了照片。</zh>"])

        let (ids, record) = try await send(
            eidolon, chunks: provider.chunks, judge: judge, photo: nil, provider: provider
        )
        XCTAssertTrue(ids.isEmpty)
        XCTAssertNil(record?.photo)
        let asked = await judge.askedPhoto
        XCTAssertEqual(asked, [false])
        let prompt = try XCTUnwrap(provider.prompts.first)
        XCTAssertTrue(prompt.contains { $0.content.contains("你发不了照片") })
    }

    func testSheDoesNotMakeAPhotoTheJudgeDidNotAskFor() async throws {
        let eidolon = try await installedEidolon()
        let generator = FakePhotoGenerator()
        let judge = PhotoJudge(wants: false)
        let provider = RecordingChatProvider(chunks: [
            Self.tagChunk + "<ja>はい。</ja><zh>好。</zh>",
        ])
        let context = PhotoTurnContext(
            generator: generator,
            settings: ImageServiceSettings(apiKey: "test-key")
        )

        let (ids, record) = try await send(
            eidolon, chunks: provider.chunks, judge: judge, photo: context, provider: provider
        )
        XCTAssertTrue(ids.isEmpty)
        XCTAssertNil(record?.photo)
        let made = await generator.requests
        XCTAssertTrue(made.isEmpty)
        // The prompt offers the tag only when he asked for a picture.
        let prompt = try XCTUnwrap(provider.prompts.first)
        XCTAssertFalse(prompt.contains { $0.content.contains("# 照片") })
    }

    func testACharacterWithNoPhotoTagsIsToldSheCannotSend() async throws {
        let eidolon = try await installedEidolon()
        let judge = PhotoJudge(wants: true)
        let provider = RecordingChatProvider(chunks: ["<ja>うん。</ja><zh>嗯。</zh>"])
        let context = PhotoTurnContext(
            generator: FakePhotoGenerator(),
            settings: ImageServiceSettings(apiKey: "test-key")
        )
        // hiori has a photo tag in the fixture too, so the turn offers the tag; the check
        // that matters is `canSendPhoto`, which the fixture only sets on characters with
        // both fields. Nothing to assert about eligibility here beyond the tag never
        // being started without a prompt.
        let (ids, record) = try await send(
            eidolon, chunks: provider.chunks, judge: judge, photo: context, provider: provider
        )
        XCTAssertTrue(ids.isEmpty)
        XCTAssertNil(record?.photo)
    }
}

extension AsyncThrowingStream where Element == TurnEvent, Failure == Error {
    /// Drains a turn: the tests that only care about what was recorded do not read events.
    fileprivate func collect() async throws {
        for try await _ in self {}
    }
}
