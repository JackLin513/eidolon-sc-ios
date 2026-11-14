import XCTest
@testable import EidolonCore

final class PhotoUniformTests: XCTestCase {
    private func character(uniform: [String]) -> CharacterConfig {
        CharacterConfig(
            id: "sakura",
            name: "夜乃桜",
            photoTag: "yoruno sakura",
            photoAppearance: ["white hair", "blue eyes"],
            photoUniform: uniform
        )
    }

    func testUniformPhotoUsesTheContentPacksUniformTags() {
        let tags = PhotoPromptBuilder.outfitTags(
            ["white school uniform", "black jacket", "yellow necktie"],
            character: character(uniform: ["white coat", "black trim", "blue skirt"])
        )
        XCTAssertEqual(tags, ["white coat", "black trim", "blue skirt"])
    }

    func testAnotherOutfitIsLeftAlone() {
        let tags = PhotoPromptBuilder.outfitTags(
            ["swimsuit", "beach"],
            character: character(uniform: ["white coat", "black trim", "blue skirt"])
        )
        XCTAssertEqual(tags, ["swimsuit", "beach"])
    }

    func testAPackWithoutAUniformKeepsTheWrittenOutfit() {
        let tags = PhotoPromptBuilder.outfitTags(
            ["white school uniform", "black jacket"],
            character: character(uniform: [])
        )
        XCTAssertEqual(tags, ["white school uniform", "black jacket"])
    }
}
