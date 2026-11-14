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
}
