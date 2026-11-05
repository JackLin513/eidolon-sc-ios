import Foundation
import XCTest
@testable import EidolonCore

/// A typed conversation can be spoken face to face: the same turns, the same records,
/// only the context she is given changes (spec #98 follow-up).
final class FaceToFaceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonFaceToFace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        return eidolon
    }

    func testAFaceToFaceTurnTellsHerTheyAreTogether() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>うん。</ja><zh>嗯。</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "おはよう",
            provider: provider,
            faceToFace: true
        ) {}
        let prompt = try XCTUnwrap(provider.prompts.first)
        XCTAssertTrue(prompt.contains { $0.role == .system && $0.content.contains("正面对面说话") })
        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(snapshot?.faceToFace, true)
    }

    func testAMessageTurnLeavesHerInTheMessageContext() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>うん。</ja><zh>嗯。</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "おはよう",
            provider: provider
        ) {}
        let prompt = try XCTUnwrap(provider.prompts.first)
        XCTAssertTrue(prompt.contains { $0.role == .system && $0.content.contains("用文字和你聊天") })
        XCTAssertFalse(prompt.contains { $0.content.contains("正面对面说话") })
        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(snapshot?.faceToFace, false)
    }

    func testTheSwitchIsKeptOnTheConversationAndANewOneStartsOff() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>うん。</ja><zh>嗯。</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "おはよう",
            provider: provider,
            faceToFace: true
        ) {}
        let current = try await eidolon.currentConversation(characterID: "mano")
        let conversation = try XCTUnwrap(current)
        XCTAssertTrue(conversation.faceToFace)

        try await eidolon.setFaceToFace(false, conversationID: conversation.id)
        let reread = try await eidolon.conversation(id: conversation.id)
        let changed = try XCTUnwrap(reread)
        XCTAssertFalse(changed.faceToFace)

        try await eidolon.beginNewConversation(characterID: "mano")
        let fresh = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(fresh?.faceToFace, false)
    }

    func testInPersonPhotoRequestsAreTakenWithHisCamera() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>いいよ。</ja><zh>好啊。</zh>"])
        let context = PhotoTurnContext(
            generator: FakePhotoGenerator(),
            settings: ImageServiceSettings(apiKey: "test-key")
        )
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "写真撮らせて",
            provider: provider,
            judge: PhotoJudge(wants: true),
            faceToFace: true,
            photo: context
        ) {}
        let prompt = try XCTUnwrap(provider.prompts.first)
        XCTAssertTrue(prompt.contains { $0.content.contains("拿着相机") })
        XCTAssertTrue(prompt.contains { $0.content.contains("shot: other") })
    }

    func testInPersonWithoutAPhotoServiceSaysSheCannotTakeOne() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>ごめん。</ja><zh>抱歉。</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "写真撮らせて",
            provider: provider,
            judge: PhotoJudge(wants: true),
            faceToFace: true
        ) {}
        let prompt = try XCTUnwrap(provider.prompts.first)
        XCTAssertTrue(prompt.contains { $0.content.contains("你们正面对面，没法拍照") })
        XCTAssertFalse(prompt.contains { $0.content.contains("你发不了照片") })
    }
}
