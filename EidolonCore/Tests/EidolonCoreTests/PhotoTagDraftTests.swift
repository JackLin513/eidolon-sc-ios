import Foundation
import XCTest
@testable import EidolonCore

final class PhotoTagDraftTests: XCTestCase {
    private func message(_ role: String, _ text: String) -> ChatMessageRecord {
        ChatMessageRecord(
            id: UUID().uuidString,
            role: role,
            text: text,
            segments: [],
            createdAt: "2026-11-05T00:00:00Z"
        )
    }

    func testTheModelDraftsATagThatParses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonDraft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        let provider = RecordingChatProvider(chunks: ["""
            好的：
            <photo>
            rating: explicit
            shot: other
            framing: cowboy shot
            place: office, on couch
            outfit: nude
            action: riding, looking at viewer
            note: 事务所沙发上的照片
            </photo>
            """])
        let draft = try await eidolon.draftPhotoTag(
            characterID: "mano",
            conversationID: nil,
            messages: [message("user", "拍张照片"), message("character", "いいよ")],
            faceToFace: true,
            adult: true,
            provider: provider
        )
        XCTAssertEqual(draft.tag.shot, .other)
        XCTAssertEqual(draft.tag.framing, .cowboyShot)
        XCTAssertEqual(draft.tag.rating, .explicit)
        XCTAssertEqual(draft.tag.action, ["riding", "looking at viewer"])
        let sent = try XCTUnwrap(provider.prompts.first)
        XCTAssertTrue(sent.contains { $0.content.contains("只输出一个 <photo>") })
        XCTAssertTrue(sent.contains { $0.content.contains("每栏尽量写 2–4 个") })
        let calls = try await eidolon.serviceCalls()
        XCTAssertEqual(calls.filter { $0.service == .chat }.count, 1)
    }

    func testAnAnswerWithoutATagFailsHere() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonDraft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        let provider = RecordingChatProvider(chunks: ["这个不好写。"])
        do {
            _ = try await eidolon.draftPhotoTag(
                characterID: "mano",
                conversationID: nil,
                messages: [message("user", "拍张照片")],
                faceToFace: true,
                adult: false,
                provider: provider
            )
            XCTFail("expected the draft to fail")
        } catch let error as PhotoTagDraftError {
            XCTAssertTrue(error.detail.contains("<photo>"))
            XCTAssertEqual(error.raw, "这个不好写。")
            XCTAssertNil(error.body)
        }
    }

    func testAFencedTagIsStillRead() throws {
        let tag = try Eidolon.photoTagFromAnswer("""
            ```html
            <photo>
            shot: selfie
            framing: upper body
            place: cafe
            outfit: casual
            action: smile
            </photo>
            ```
            """)
        XCTAssertEqual(tag.shot, .selfie)
    }

    func testChineseColumnsAndValuesAreRead() throws {
        let tag = try PhotoTag(text: """
            拍摄：自拍
            景别：上半身
            地点：办公室，沙发
            服装：裸
            动作：骑乘
            """)
        XCTAssertEqual(tag.shot, .selfie)
        XCTAssertEqual(tag.framing, .upperBody)
        XCTAssertEqual(tag.place, ["办公室", "沙发"])
        XCTAssertEqual(tag.outfit, ["裸"])
        XCTAssertEqual(tag.action, ["骑乘"])
    }

    func testBulletsAndFullWidthPunctuationAreTolerated() throws {
        let tag = try PhotoTag(text: """
            - shot：other
            * framing: full-body
            • place: office, on couch
            outfit: nude
            action: riding  # 正在做的事
            """)
        XCTAssertEqual(tag.shot, .other)
        XCTAssertEqual(tag.framing, .fullBody)
        XCTAssertEqual(tag.place, ["office", "on couch"])
        XCTAssertEqual(tag.action, ["riding"])
    }

    func testAnExplanationInBracketsIsDroppedFromATag() throws {
        let tag = try PhotoTag(text: """
            shot: other
            framing: upper body
            place: office (in the afternoon)
            outfit: black skirt, white blouse (blouse untucked)
            action: riding (on his lap)
            """)
        XCTAssertEqual(tag.place, ["office"])
        XCTAssertEqual(tag.outfit, ["black skirt", "white blouse"])
        XCTAssertEqual(tag.action, ["riding"])
    }

    func testAMissingColumnFallsBackToTheDefault() throws {
        let tag = try PhotoTag(text: """
            shot: other
            framing: cowboy shot
            outfit: nude
            """)
        XCTAssertTrue(tag.place.isEmpty)
        XCTAssertEqual(tag.outfit, ["nude"])
        let cleaned = tag.sanitized(using: TestPhotoTagTable.make(), adult: true)
        XCTAssertEqual(cleaned.place, ["indoors"])
        XCTAssertEqual(cleaned.outfit, ["nude"])
    }

    func testABadTagShowsWhatTheModelWrote() {
        do {
            _ = try Eidolon.photoTagFromAnswer("<photo>\nshot: unknown\n</photo>")
            XCTFail("expected a draft error")
        } catch let error as PhotoTagDraftError {
            XCTAssertEqual(error.body?.contains("shot: unknown"), true)
            XCTAssertFalse(error.raw.isEmpty)
        } catch {
            XCTFail("\(error)")
        }
    }

}
