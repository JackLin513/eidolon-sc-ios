import Foundation
import XCTest
@testable import EidolonCore

/// The connection Soniox sees while her voice closes the microphone (spec「识别连接」).
final class SonioxKeepaliveTests: XCTestCase {
    func testTheConnectionIsKeptAliveOnceItHasGoneWithoutAudio() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(SonioxKeepalive.isDue(now: now, lastAudio: now.addingTimeInterval(-0.5)))
        XCTAssertTrue(SonioxKeepalive.isDue(now: now, lastAudio: now.addingTimeInterval(-1)))
        XCTAssertTrue(SonioxKeepalive.isDue(now: now, lastAudio: now.addingTimeInterval(-5)))
    }

    /// Pipecat's Soniox service checks every 5 seconds and sends its protocol keepalive
    /// after 1 second without audio (`soniox/stt.py`, `stt_service.py`).
    func testItFollowsPipicatsSonioxConfiguration() {
        XCTAssertEqual(SonioxKeepalive.interval, .seconds(5))
        XCTAssertEqual(SonioxKeepalive.idle, .seconds(1))
        XCTAssertEqual(SonioxKeepalive.message, #"{"type": "keepalive"}"#)
    }
}
