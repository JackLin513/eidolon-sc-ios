import XCTest
@testable import EidolonCore

final class APIServiceRoutingTests: XCTestCase {
    func testDeepSeekMovesToItsAnthropicBaseAndBack() {
        XCTAssertEqual(
            APIServiceRouting.baseURL(
                "https://api.deepseek.com", movingTo: .anthropic, from: .chatCompletions
            ),
            "https://api.deepseek.com/anthropic"
        )
        XCTAssertEqual(
            APIServiceRouting.baseURL(
                "https://api.deepseek.com/v1/", movingTo: .anthropic, from: .responses
            ),
            "https://api.deepseek.com/anthropic"
        )
        XCTAssertEqual(
            APIServiceRouting.baseURL(
                "https://api.deepseek.com/anthropic", movingTo: .chatCompletions, from: .anthropic
            ),
            "https://api.deepseek.com"
        )
        XCTAssertEqual(
            APIServiceRouting.baseURL(
                "https://api.deepseek.com/anthropic/v1", movingTo: .responses, from: .anthropic
            ),
            "https://api.deepseek.com"
        )
    }

    func testOtherBasesAreLeftAlone() {
        XCTAssertEqual(
            APIServiceRouting.baseURL(
                "https://api.anthropic.com/v1", movingTo: .anthropic, from: .chatCompletions
            ),
            "https://api.anthropic.com/v1"
        )
        XCTAssertEqual(
            APIServiceRouting.baseURL(
                "https://relay.example.com/v1", movingTo: .anthropic, from: .responses
            ),
            "https://relay.example.com/v1"
        )
        XCTAssertEqual(
            APIServiceRouting.baseURL("", movingTo: .anthropic, from: .chatCompletions),
            ""
        )
    }

    func testAnImportedDeepSeekAnthropicModelGetsItsPrefix() {
        XCTAssertEqual(
            APIServiceRouting.baseURLForImportedSettings(
                "https://api.deepseek.com", protocol: .anthropic
            ),
            "https://api.deepseek.com/anthropic"
        )
        XCTAssertEqual(
            APIServiceRouting.baseURLForImportedSettings(
                "https://relay.example.com/v1", protocol: .anthropic
            ),
            "https://relay.example.com/v1"
        )
    }

    func testTheRetrievalDefaultFillsOnlyABlankAddress() {
        XCTAssertEqual(
            APIServiceRouting.retrievalBaseURL(""),
            "https://api.siliconflow.cn/v1"
        )
        XCTAssertEqual(
            APIServiceRouting.retrievalBaseURL("  "),
            "https://api.siliconflow.cn/v1"
        )
        XCTAssertEqual(
            APIServiceRouting.retrievalBaseURL("https://relay.example.com/v1"),
            "https://relay.example.com/v1"
        )
    }
}
