import Foundation
import XCTest
@testable import EidolonCore

/// Installs a real exported bundle when one is supplied through
/// `EIDOLON_TEST_BUNDLE`, so the import path is exercised against real data and
/// not only against fixtures.
final class RealBundleSmokeTests: XCTestCase {
    private func bundleURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["EIDOLON_TEST_BUNDLE"] else {
            throw XCTSkip("设置 EIDOLON_TEST_BUNDLE 后才运行真实内容包测试")
        }
        return URL(fileURLWithPath: path)
    }

    func testInstallsRealBundle() async throws {
        let bundle = try bundleURL()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonReal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let eidolon = try Eidolon(location: .init(root: root))
        let info = try await eidolon.install(bundleAt: bundle)

        XCTAssertGreaterThan(info.episodeCount, 0)
        XCTAssertGreaterThan(info.passageCount, 0)
        XCTAssertGreaterThan(info.characterCount, 0)
        XCTAssertEqual(info.embeddingDimensions, 1024)
        XCTAssertEqual(info.embeddingModel, "Qwen/Qwen3-Embedding-0.6B")

        let characters = try await eidolon.characters()
        XCTAssertEqual(characters.count, info.characterCount)
        XCTAssertTrue(characters.contains { $0.id == "mano" })

        let manoPassages = try await eidolon.episodeCount(characterID: "mano")
        XCTAssertGreaterThan(manoPassages, 0)
    }
}
