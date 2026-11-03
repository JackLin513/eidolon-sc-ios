import XCTest
@testable import EidolonCore

final class EmbeddingSpaceTests: XCTestCase {
    func testTheServiceComesFromTheBundlesModel() {
        XCTAssertEqual(
            ContentEmbeddingSpace(model: "Qwen/Qwen3-Embedding-0.6B", dimensions: 1024).service,
            .siliconflow
        )
        XCTAssertEqual(
            ContentEmbeddingSpace(model: "gemini-embedding-2", dimensions: 1536).service,
            .gemini
        )
        XCTAssertEqual(
            ContentEmbeddingSpace(model: "Gemini-Embedding-2", dimensions: 1536).service,
            .gemini
        )
    }

    func testAModelThatIsNotGeminiStaysOnSiliconFlow() {
        XCTAssertEqual(EmbeddingService(model: "Qwen/Qwen3-Embedding-4B"), .siliconflow)
        XCTAssertEqual(EmbeddingService.defaultSiliconFlowModel, "Qwen/Qwen3-Embedding-0.6B")
        XCTAssertEqual(EmbeddingService.defaultGeminiModel, "gemini-embedding-2")
    }
}
