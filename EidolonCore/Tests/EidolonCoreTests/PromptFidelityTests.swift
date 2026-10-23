import Foundation
import XCTest
@testable import EidolonCore

/// The prompt is the persona's behaviour: these tests keep the port word for word with
/// upstream (ADR-0004), using text upstream rendered itself.
final class PromptFidelityTests: XCTestCase {
    private func resource(_ name: String, _ ext: String) throws -> URL {
        let url = Bundle.module.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Resources"
        )
        return try XCTUnwrap(url, "missing resource \(name).\(ext)")
    }

    func testWorldPromptMatchesUpstream() throws {
        let world = try WorldSetting(json: Data(contentsOf: resource("world", "json")))
        let expected = try String(contentsOf: resource("world-mano", "txt"), encoding: .utf8)

        let rendered = world.prompt(name: "櫻木真乃", today: "2026-10-23")
        XCTAssertEqual(rendered, expected)
    }

    func testStaffWorldPromptHasNoSongsOrLives() throws {
        let world = try WorldSetting(json: Data(contentsOf: resource("world", "json")))
        let rendered = world.prompt(name: "七草はづき", today: "2026-10-23")
        XCTAssertFalse(rendered.contains("# 你的歌"))
        XCTAssertFalse(rendered.contains("# 你上过的演出"))
        XCTAssertTrue(rendered.contains("# 世界设定"))
    }

    func testProducerDefaultPromptMatchesUpstream() throws {
        let expected = try String(contentsOf: resource("producer-default", "txt"), encoding: .utf8)
        XCTAssertEqual(ProducerProfile.default.prompt, expected)
    }

    func testFormatInstructionsMatchUpstream() throws {
        let expected = try String(contentsOf: resource("format-instructions", "txt"), encoding: .utf8)
        XCTAssertEqual(ReplyFormatInstructions.text, expected)
    }

    func testDirectedFormatInstructionsMatchUpstream() throws {
        let expected = try String(
            contentsOf: resource("format-instructions-directed", "txt"),
            encoding: .utf8
        )
        XCTAssertEqual(ReplyFormatInstructions.directed, expected)
    }

    func testTheVoiceModelChoosesTheInstructions() {
        // Only drama-3 reads paired tags and directions (upstream `TAG_READERS`).
        XCTAssertEqual(
            ReplyFormatInstructions.forVoice(model: "drama-3"),
            ReplyFormatInstructions.directed
        )
        XCTAssertEqual(
            ReplyFormatInstructions.forVoice(model: "s2.1-pro-free"),
            ReplyFormatInstructions.text
        )
        XCTAssertEqual(
            ReplyFormatInstructions.forVoice(model: "s2.1-pro"),
            ReplyFormatInstructions.text
        )
        XCTAssertEqual(
            ReplyFormatInstructions.forVoice(model: nil),
            ReplyFormatInstructions.text
        )
    }

    // MARK: - Assembly order

    func testPromptFollowsUpstreamOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptOrder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sheets = root.appendingPathComponent("characters/sheets", isDirectory: true)
        try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        try "# 真乃的人设\n".write(
            to: sheets.appendingPathComponent("mano.md"),
            atomically: true,
            encoding: .utf8
        )

        let character = CharacterConfig(
            id: "mano",
            name: "櫻木真乃",
            sheet: "characters/sheets/mano.md"
        )
        let assembler = PromptAssembler(
            bundleDirectory: root,
            character: character,
            world: nil,
            producer: .default,
            today: "2026-10-23",
            nowSection: nil
        )
        let history = [
            StoredMessage(id: "1", role: "user", text: "おはよう", segments: []),
            StoredMessage(
                id: "2",
                role: "character",
                text: nil,
                segments: [ReplySegment(ja: "おはよう", zh: "早上好")]
            ),
        ]
        let messages = try assembler.prompt(history: history, text: "今日は何する？")

        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertTrue(messages[0].content.hasPrefix("# 真乃的人设"))
        XCTAssertTrue(messages[0].content.hasSuffix(ReplyFormatInstructions.text))
        XCTAssertEqual(messages[1], PromptMessage(.system, ProducerProfile.default.prompt))
        XCTAssertEqual(messages[2], PromptMessage(.user, "おはよう"))
        XCTAssertEqual(messages[3], PromptMessage(.assistant, "<ja>おはよう</ja><zh>早上好</zh>"))
        XCTAssertEqual(messages[4], PromptMessage(.user, "今日は何する？"))
    }
}
