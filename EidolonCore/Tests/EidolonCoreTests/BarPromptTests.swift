import Foundation
import XCTest
@testable import EidolonCore

/// The package-replaceable part of the bar prompt (issue #148): old packages keep the SC text
/// byte for byte, new ones may replace only the three static blocks.
final class BarPromptTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eidolon-bar-prompt-\(UUID().uuidString)", isDirectory: true)
        try BarFixture.write(to: root)
        return root
    }

    func testAPackageWithoutAPromptKeepsTheSCBlocksExactly() throws {
        let root = try directory()
        let content = try BarContent(directory: root)
        XCTAssertEqual(content.prompt, .default)

        let shared = BarPrompt.shared(sheet: "SHEET", birthday: "BIRTHDAY", world: "WORLD")
        XCTAssertEqual(
            shared,
            [["SHEET", "BIRTHDAY", "WORLD"], [BarPrompt.barIF, BarPrompt.writing, BarPrompt.format]]
                .flatMap { $0 }.joined(separator: "\n\n")
        )
    }

    func testAPackagePromptReplacesTheThreeStaticBlocks() throws {
        let root = try directory()
        let template = BarPromptTemplate(
            barIF: "IF DIMENSION LOVER", writing: "WRITING DIMENSION LOVER",
            format: "FORMAT DIMENSION LOVER"
        )
        try JSONEncoder().encode(template)
            .write(to: root.appendingPathComponent("characters/bar_prompt.json"))

        let content = try BarContent(directory: root)
        XCTAssertEqual(content.prompt, template)
        let shared = BarPrompt.shared(
            sheet: "SHEET", birthday: "BIRTHDAY", world: "WORLD", template: content.prompt
        )
        XCTAssertTrue(shared.contains("IF DIMENSION LOVER"))
        XCTAssertTrue(shared.contains("WRITING DIMENSION LOVER"))
        XCTAssertTrue(shared.hasSuffix("FORMAT DIMENSION LOVER"))
        XCTAssertFalse(shared.contains(BarPrompt.barIF))
    }

    func testAnEmptyBlockIsRefused() throws {
        let root = try directory()
        let template = BarPromptTemplate(barIF: "", writing: "WRITING", format: "FORMAT")
        try JSONEncoder().encode(template)
            .write(to: root.appendingPathComponent("characters/bar_prompt.json"))
        XCTAssertThrowsError(try BarContent(directory: root)) { error in
            XCTAssertTrue("\(error)".contains("bar_if"))
        }
    }

    func testSnakeCaseFieldsDecode() throws {
        let json = """
        {"bar_if":"IF","writing":"WRITING","format":"FORMAT"}
        """.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(BarPromptTemplate.self, from: json),
            BarPromptTemplate(barIF: "IF", writing: "WRITING", format: "FORMAT")
        )
    }

    func testAPackageTutorialNamesFileReplacesOnlyTheAddress() throws {
        let root = try directory()
        try Data(#"{"producer":"槐","producer_ja":"槐さん"}"#.utf8)
            .write(to: root.appendingPathComponent("characters/bar_tutorial.json"))
        let content = try BarContent(directory: root)
        XCTAssertEqual(content.tutorialNames, BarTutorialNames(producer: "槐", producerJa: "槐さん"))
    }

    func testAPackageWithoutTutorialNamesKeepsSCDefaults() throws {
        let content = try BarContent(directory: try directory())
        XCTAssertNil(content.tutorialNames)
    }
}
