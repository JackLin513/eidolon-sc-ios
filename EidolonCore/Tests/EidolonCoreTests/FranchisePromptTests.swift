import Foundation
import Testing
@testable import EidolonCore

@Suite("Franchise prompt")
struct FranchisePromptTests {
    @Test("a package prompt loads and replaces the built-in identity")
    func load() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "franchise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "characters"), withIntermediateDirectories: true)
        let prompt = FranchisePrompt(
            workName: "Work", organization: "Org",
            judgeScene: "JUDGE", callScene: "CALL", producerLine: "PRODUCER",
            memoryInstructions: "MEMORY", titleInstructions: "TITLE"
        )
        try JSONEncoder().encode(prompt).write(to: root.appending(path: "characters/franchise.json"))
        let loaded = try #require(FranchisePrompt.load(in: root))
        #expect(loaded.judgeScene == "JUDGE")
        #expect(loaded.producerLine == "PRODUCER")
    }

    @Test("the SC built-in localizes nothing")
    func shinyIsByteIdentical() {
        #expect(FranchisePrompt.shiny.localized("283 事务所的制作人和偶像") == "283 事务所的制作人和偶像")
        #expect(FranchisePrompt.shiny.vocabulary == nil)
        #expect(FranchisePrompt.shiny.userSection == nil)
    }

    @Test("a custom vocabulary replaces the producer vocabulary longest-first")
    func localizeVocabulary() {
        let prompt = FranchisePrompt(
            workName: "Work", organization: "Org",
            judgeScene: "JUDGE", callScene: "CALL", producerLine: "PRODUCER",
            memoryInstructions: "MEMORY", titleInstructions: "TITLE",
            vocabulary: ["283 事务所": "学园", "制作人": "槐", "偶像": "角色", "事务所": "学园"]
        )
        #expect(prompt.localized("283 事务所的制作人和偶像") == "学园的槐和角色")
        #expect(prompt.localized("制作人在事务所") == "槐在学园")
    }

    @Test("the totsulover built-in no longer calls the user a producer")
    func totsuloverIdentity() {
        let prompt = FranchisePrompt.totsulover
        #expect(prompt.producerRole == "主人公")
        #expect(prompt.protagonistTerm == "槐")
        #expect(prompt.userSection?.contains("崩月槐") == true)
        #expect(prompt.userSection?.contains("槐くん") == true)
        #expect(prompt.userSection?.contains("槐さん") == true)
        #expect(prompt.userSection?.contains("槐お兄ちゃん") == true)
        #expect(prompt.userSection?.contains("男主角") == false)
        #expect(prompt.judgeScene.contains("制作人") == false)
        #expect(prompt.callScene.contains("制作人") == false)
        #expect(prompt.memoryInstructions.contains("制作人") == false)
        #expect(prompt.titleInstructions.contains("制作人") == false)
        #expect(prompt.judgeScene.contains("男主角") == false)
        #expect(prompt.adultBoundary?.contains("成人亲密") == true)
    }

    @Test("the new optional identity fields decode from snake_case JSON")
    func decodeIdentityOverrides() throws {
        let json = """
        {"work_name":"W","organization":"O","producer_role":"主人公","language":"ja",
         "judge_scene":"J","call_scene":"C","producer_line":"P",
         "memory_instructions":"M","title_instructions":"T",
         "protagonist_term":"槐","user_section":"U","adult_boundary":"A",
         "world_prompt":"W","vocabulary":{"制作人":"槐"}}
        """
        let prompt = try JSONDecoder().decode(FranchisePrompt.self, from: Data(json.utf8))
        #expect(prompt.protagonistTerm == "槐")
        #expect(prompt.userSection == "U")
        #expect(prompt.adultBoundary == "A")
        #expect(prompt.worldPrompt == "W")
        #expect(prompt.localized("制作人") == "槐")
    }
}
