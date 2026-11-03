import Foundation
import XCTest
@testable import EidolonCore

final class EnvImportTests: XCTestCase {
    // MARK: Parsing

    func testParsingReadsUpstreamShapes() {
        let file = EnvParser.parse(text: """
            # comment
            export CHAT_LLM_MODEL=some-model
            CHAT_LLM_BASE_URL = "https://example.com/v1"
            FISH_AUDIO_API_KEY='sk-secret'
            EMPTY=
            export   BAD-KEY=x
            NOT A KEY
            """)
        XCTAssertEqual(file.entries.map(\.key), [
            "CHAT_LLM_MODEL", "CHAT_LLM_BASE_URL", "FISH_AUDIO_API_KEY", "EMPTY",
        ])
        XCTAssertEqual(file.entries[1].value, "https://example.com/v1")
        XCTAssertEqual(file.entries[2].value, "sk-secret")
        XCTAssertEqual(file.entries[3].value, "")
        XCTAssertEqual(file.issues.count, 2)
        XCTAssertEqual(file.issues[0].line, 6)
    }

    func testDoubleQuotesUnescapeButSingleQuotesDoNot() {
        let file = EnvParser.parse(text: #"""
            A="line\nquote\"done"
            B='line\nquote'
            """#)
        XCTAssertEqual(file.entries[0].value, "line\nquote\"done")
        XCTAssertEqual(file.entries[1].value, "line\\nquote")
    }

    func testABOMAndWindowsLineEndingsAreRead() {
        let file = EnvParser.parse(text: "\u{FEFF}CHAT_LLM_MODEL=one\r\nSONIOX_API_KEY=two\r\n")
        XCTAssertEqual(file.entries.map(\.key), ["CHAT_LLM_MODEL", "SONIOX_API_KEY"])
        XCTAssertEqual(file.entries[1].value, "two")
        XCTAssertTrue(file.issues.isEmpty)
    }

    func testANonUTF8FileIsRefused() {
        let data = Data([0xFF, 0xFE, 0x00])
        XCTAssertThrowsError(try EnvParser.parse(data: data)) { error in
            XCTAssertEqual(error as? EnvFileError, .notUTF8)
        }
    }

    func testAnOversizedFileIsRefused() {
        let data = Data(repeating: 0x41, count: EnvParser.maxBytes + 1)
        XCTAssertThrowsError(try EnvParser.parse(data: data)) { error in
            XCTAssertEqual(error as? EnvFileError, .tooLarge)
        }
    }

    // MARK: Mapping

    func testTheUpstreamKeysMapToTheAppSettings() {
        let file = EnvParser.parse(text: """
            CHAT_LLM_PROTOCOL=responses
            CHAT_LLM_BASE_URL=https://api.example.com/v1
            CHAT_LLM_API_KEY=chat-key
            CHAT_LLM_MODEL=chat-model
            CHAT_LLM_MAX_TOKENS=4096
            CHAT_LLM_REASONING_EFFORT=low
            CHAT_LLM_CALL_REASONING_EFFORT=none
            CHAT_LLM_EXTRA_BODY={"enable_thinking": false}
            BACKGROUND_LLM_MODEL=cheap
            BACKGROUND_LLM_API_KEY=bg-key
            JUDGE_PROVIDER=jev
            JEV_API_KEY=jev-key
            JEV_MODEL=typesafe/jev-1.13
            JEV_BASE_URL=https://openrouter.ai/api/v1
            SILICONFLOW_API_KEY=sf-key
            SILICONFLOW_BASE_URL=https://api.siliconflow.cn/v1
            EMBEDDING_MODEL=Qwen/Qwen3-Embedding-0.6B
            RERANK_MODEL=Qwen/Qwen3-Reranker-0.6B
            STT_PROVIDER=soniox
            SONIOX_API_KEY=soniox-key
            FISH_AUDIO_API_KEY=fish-key
            FISH_AUDIO_MODEL=drama-3
            """)
        let report = EnvImporter.map(file)
        let values = report.values
        XCTAssertEqual(values.chatProtocol, .responses)
        XCTAssertEqual(values.chatBaseURL, "https://api.example.com/v1")
        XCTAssertEqual(values.chatAPIKey, "chat-key")
        XCTAssertEqual(values.chatModel, "chat-model")
        XCTAssertEqual(values.chatMaxTokens, 4096)
        XCTAssertEqual(values.chatReasoningEffort, .low)
        XCTAssertEqual(values.chatCallReasoningEffort, ReasoningEffort.none)
        XCTAssertEqual(values.chatExtraBody, ["enable_thinking": .bool(false)])
        XCTAssertEqual(values.backgroundModel, "cheap")
        XCTAssertEqual(values.backgroundAPIKey, "bg-key")
        XCTAssertEqual(values.judgeService, .jev)
        XCTAssertEqual(values.jevAPIKey, "jev-key")
        XCTAssertEqual(values.jevBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(values.siliconflowAPIKey, "sf-key")
        XCTAssertEqual(values.embeddingModel, "Qwen/Qwen3-Embedding-0.6B")
        XCTAssertEqual(values.rerankModel, "Qwen/Qwen3-Reranker-0.6B")
        XCTAssertEqual(values.speechToText, .soniox)
        XCTAssertEqual(values.sonioxAPIKey, "soniox-key")
        XCTAssertEqual(values.fishAPIKey, "fish-key")
        XCTAssertEqual(values.fishModel, "drama-3")
        XCTAssertTrue(report.invalid.isEmpty, "\(report.invalid)")
        XCTAssertTrue(report.unknown.isEmpty, "\(report.unknown)")
    }

    func testCloudflareAndBailianJudgeKeysMap() {
        let report = EnvImporter.map(EnvParser.parse(text: """
            CLOUDFLARE_API_TOKEN=cf-key
            CLOUDFLARE_ACCOUNT_ID=acc
            CLOUDFLARE_JUDGE_MODEL=clef
            BAILIAN_JUDGE_API_KEY=bl-key
            BAILIAN_JUDGE_WORKSPACE_ID=llm-1
            BAILIAN_JUDGE_REGION=singapore
            BAILIAN_JUDGE_MODEL=decision-model-preview
            """))
        XCTAssertEqual(report.values.cloudflareAPIKey, "cf-key")
        XCTAssertEqual(report.values.cloudflareAccountID, "acc")
        XCTAssertEqual(report.values.cloudflareModel, "clef")
        XCTAssertEqual(report.values.bailianJudgeAPIKey, "bl-key")
        XCTAssertEqual(report.values.bailianWorkspace, "llm-1")
        XCTAssertEqual(report.values.bailianRegion, .singapore)
        XCTAssertEqual(report.values.bailianModel, "decision-model-preview")
    }

    func testBlankValuesDoNotOverwrite() {
        let report = EnvImporter.map(EnvParser.parse(text: """
            CHAT_LLM_MODEL=
            CHAT_LLM_API_KEY=
            SILICONFLOW_API_KEY=
            """))
        XCTAssertNil(report.values.chatModel)
        XCTAssertNil(report.values.chatAPIKey)
        XCTAssertNil(report.values.siliconflowAPIKey)
        XCTAssertTrue(report.mapped.isEmpty)
    }

    func testUpstreamKeysIOSDoesNotReadAreUnsupportedNotUnknown() {
        let report = EnvImporter.map(EnvParser.parse(text: """
            EIDOLON_CALL_MINUTES=10
            EIDOLON_DOMAIN=example.com
            NOVELAI_API_KEY=nai
            GPT_IMAGE_MODEL=gpt-image-2
            DASHSCOPE_API_KEY=dash
            BAILIAN_STT_MODEL=qwen-audio-3.1-asr-flash-streaming
            RERANK_MIN_RELEVANCE=0.3
            SOMETHING_ELSE=1
            """))
        XCTAssertEqual(
            Set(report.unsupported.map(\.key)),
            [
                "EIDOLON_CALL_MINUTES", "EIDOLON_DOMAIN",
                "NOVELAI_API_KEY", "GPT_IMAGE_MODEL", "DASHSCOPE_API_KEY",
                "BAILIAN_STT_MODEL", "RERANK_MIN_RELEVANCE",
            ]
        )
        XCTAssertEqual(report.unknown.map(\.key), ["SOMETHING_ELSE"])
    }

    func testInvalidValuesAreReportedAndNotApplied() {
        let report = EnvImporter.map(EnvParser.parse(text: """
            CHAT_LLM_PROTOCOL=claude
            CHAT_LLM_MAX_TOKENS=²
            CHAT_LLM_REASONING_EFFORT=turbo
            CHAT_LLM_EXTRA_BODY={"model":"other"}
            JUDGE_PROVIDER=chat
            """))
        XCTAssertNil(report.values.chatProtocol)
        XCTAssertNil(report.values.chatMaxTokens)
        XCTAssertNil(report.values.chatReasoningEffort)
        XCTAssertNil(report.values.chatExtraBody)
        XCTAssertNil(report.values.judgeService)
        XCTAssertEqual(Set(report.invalid.map(\.key)), [
            "CHAT_LLM_PROTOCOL", "CHAT_LLM_MAX_TOKENS",
            "CHAT_LLM_REASONING_EFFORT", "CHAT_LLM_EXTRA_BODY", "JUDGE_PROVIDER",
        ])
    }

    func testAnthropicRefusesMinimal() {
        let report = EnvImporter.map(EnvParser.parse(text: """
            CHAT_LLM_PROTOCOL=anthropic
            CHAT_LLM_REASONING_EFFORT=minimal
            """))
        XCTAssertNil(report.values.chatReasoningEffort)
        XCTAssertEqual(report.invalid.map(\.key), ["CHAT_LLM_REASONING_EFFORT"])
    }

    func testAnthropicRefusesMinimalThroughTheInheritedProtocolForBackground() {
        let report = EnvImporter.map(EnvParser.parse(text: """
            CHAT_LLM_PROTOCOL=anthropic
            BACKGROUND_LLM_REASONING_EFFORT=minimal
            """))
        XCTAssertNil(report.values.backgroundReasoningEffort)
        XCTAssertEqual(report.invalid.map(\.key), ["BACKGROUND_LLM_REASONING_EFFORT"])
    }

    func testEmbeddingModelConflictingWithTheBundleIsNotApplied() {
        let bundle = ContentEmbeddingSpace(
            model: "Qwen/Qwen3-Embedding-0.6B",
            dimensions: 1024
        )
        let report = EnvImporter.map(EnvParser.parse(text: """
            EMBEDDING_MODEL=gemini-embedding-2
            EMBEDDING_DIMENSIONS=1536
            SILICONFLOW_API_KEY=sf-key
            """), contentEmbedding: bundle)
        XCTAssertNil(report.values.embeddingModel)
        XCTAssertNil(report.values.embeddingDimensions)
        XCTAssertEqual(report.values.siliconflowAPIKey, "sf-key")
        XCTAssertEqual(Set(report.conflicts.map(\.key)), ["EMBEDDING_MODEL", "EMBEDDING_DIMENSIONS"])
    }

    func testEmbeddingModelMatchingTheBundleIsApplied() {
        let bundle = ContentEmbeddingSpace(
            model: "Qwen/Qwen3-Embedding-0.6B",
            dimensions: 1024
        )
        let report = EnvImporter.map(EnvParser.parse(text: """
            EMBEDDING_MODEL=Qwen/Qwen3-Embedding-0.6B
            EMBEDDING_DIMENSIONS=1024
            """), contentEmbedding: bundle)
        XCTAssertEqual(report.values.embeddingModel, "Qwen/Qwen3-Embedding-0.6B")
        XCTAssertEqual(report.values.embeddingDimensions, 1024)
        XCTAssertTrue(report.conflicts.isEmpty)
    }

    func testADuplicateKeyIsNotedAndTheLastLineWins() {
        let report = EnvImporter.map(EnvParser.parse(text: """
            CHAT_LLM_MODEL=first
            CHAT_LLM_MODEL=second
            """))
        XCTAssertEqual(report.values.chatModel, "second")
        XCTAssertEqual(report.conflicts.map(\.key), ["CHAT_LLM_MODEL"])
    }

    func testSecretsAreMarkedAndTheirLabelsSaySo() {
        let report = EnvImporter.map(EnvParser.parse(text: """
            CHAT_LLM_API_KEY=secret
            SONIOX_API_KEY=secret2
            """))
        XCTAssertEqual(Set(report.mapped.filter(\.secret).map(\.key)), [
            "CHAT_LLM_API_KEY", "SONIOX_API_KEY",
        ])
    }

    func testAFileWithNothingRecognizedSaysSo() {
        let report = EnvImporter.map(EnvParser.parse(text: "# only comments\n\n"))
        XCTAssertEqual(report.blockingError, .empty)
    }

    func testGeminiEmbeddingIsImportedAndBailianSTTIsStillUnsupported() {
        let report = EnvImporter.map(EnvParser.parse(text: """
            EMBEDDING_PROVIDER=gemini
            GEMINI_API_KEY=gem
            GEMINI_BASE_URL=https://generativelanguage.googleapis.com/v1beta
            EMBEDDING_MODEL=gemini-embedding-2
            EMBEDDING_DIMENSIONS=1536
            STT_PROVIDER=bailian
            """))
        XCTAssertEqual(report.values.embeddingService, .gemini)
        XCTAssertEqual(report.values.geminiAPIKey, "gem")
        XCTAssertEqual(report.values.geminiBaseURL, "https://generativelanguage.googleapis.com/v1beta")
        XCTAssertEqual(report.values.embeddingModel, "gemini-embedding-2")
        XCTAssertEqual(report.values.embeddingDimensions, 1536)
        XCTAssertEqual(report.unsupported.map(\.key), ["STT_PROVIDER"])
        XCTAssertNil(report.values.speechToText)
    }

    func testGeminiProviderConflictingWithTheBundleIsNotApplied() {
        let bundle = ContentEmbeddingSpace(
            model: "Qwen/Qwen3-Embedding-0.6B",
            dimensions: 1024
        )
        let report = EnvImporter.map(EnvParser.parse(text: """
            EMBEDDING_PROVIDER=gemini
            GEMINI_API_KEY=gem
            """), contentEmbedding: bundle)
        XCTAssertNil(report.values.embeddingService)
        XCTAssertEqual(report.values.geminiAPIKey, "gem")
        XCTAssertEqual(report.conflicts.map(\.key), ["EMBEDDING_PROVIDER"])
    }

    func testSiliconFlowProviderIsAccepted() {
        let report = EnvImporter.map(EnvParser.parse(text: "EMBEDDING_PROVIDER=siliconflow"))
        XCTAssertEqual(report.values.embeddingService, .siliconflow)
        XCTAssertTrue(report.unsupported.isEmpty)
    }
}
