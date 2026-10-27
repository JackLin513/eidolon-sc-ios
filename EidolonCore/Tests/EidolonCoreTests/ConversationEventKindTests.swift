import Foundation
import XCTest
@testable import EidolonCore

/// What happened in a conversation, read from the string the library keeps (#35 review,
/// GLOSSARY.md「对话事件」).
final class ConversationEventKindTests: XCTestCase {
    /// The raw values are exactly the ones the library writes; a round trip changes nothing.
    func testItKeepsTheStoredRawValue() {
        XCTAssertEqual(ConversationEventKind(stored: "hung_up"), .hungUp)
        XCTAssertEqual(ConversationEventKind(stored: "hung_up").rawValue, "hung_up")
        XCTAssertEqual(ConversationEventKind(stored: "ended"), .ended)
        XCTAssertEqual(ConversationEventKind(stored: "ended").rawValue, "ended")
    }

    /// Each known event says the same thing in the chat, the list and her prompt.
    func testKnownEventsSayWhatHappened() {
        XCTAssertEqual(ConversationEventKind.hungUp.displayText, "她挂断了电话")
        XCTAssertEqual(ConversationEventKind.hungUp.narration, "（你挂断了制作人的电话。）")
        XCTAssertEqual(ConversationEventKind.hungUp.icon, "phone.down")

        XCTAssertEqual(ConversationEventKind.ended.displayText, "她结束了对话")
        XCTAssertEqual(ConversationEventKind.ended.narration, "（你结束了和制作人的对话。）")
        XCTAssertEqual(ConversationEventKind.ended.icon, "moon.zzz")
    }

    /// A kind this build does not know — from a newer build, or an old one this app has no
    /// words for — is kept as it is and shown generically; she is not told of it.
    func testAnUnknownEventFallsBackToTheGenericWords() {
        let kind = ConversationEventKind(stored: "something_new")
        XCTAssertEqual(kind, .other("something_new"))
        XCTAssertEqual(kind.rawValue, "something_new")
        XCTAssertEqual(kind.displayText, "通话结束")
        XCTAssertNil(kind.narration)
        XCTAssertEqual(kind.icon, "phone.down")
    }
}
