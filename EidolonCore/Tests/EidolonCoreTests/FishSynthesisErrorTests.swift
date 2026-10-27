import Foundation
import XCTest
@testable import EidolonCore

/// When Fish Audio is refusing the call as a service, and when only one segment was lost
/// (ADR-0011, #35 no. 37).
final class FishSynthesisErrorTests: XCTestCase {
    /// A refused or missing key, no credit, and an empty answer are the service itself,
    /// whatever this call has done before.
    func testTheServiceItselfFailing() {
        for hasSynthesized in [false, true] {
            XCTAssertNotNil(
                FishSynthesisError.missingKey.serviceFailure(hasSynthesized: hasSynthesized)
            )
            XCTAssertNotNil(
                FishSynthesisError.empty.serviceFailure(hasSynthesized: hasSynthesized)
            )
            for code in [401, 402, 403] {
                XCTAssertNotNil(
                    FishSynthesisError.status(code, "no")
                        .serviceFailure(hasSynthesized: hasSynthesized),
                    "\(code)"
                )
            }
        }
    }

    /// 400, 404 and 422 may be about this one request: before any segment has been made
    /// they are the service not serving this call at all, and after one they are a lost
    /// segment (a caller could not tell a bad voice from a bad line otherwise).
    func testARequestRefusedIsTheServiceOnlyBeforeAnythingIsMade() {
        for code in [400, 404, 422] {
            XCTAssertNotNil(
                FishSynthesisError.status(code, "no").serviceFailure(hasSynthesized: false),
                "\(code) before a segment"
            )
            XCTAssertNil(
                FishSynthesisError.status(code, "no").serviceFailure(hasSynthesized: true),
                "\(code) after a segment"
            )
        }
    }

    /// A timeout, a dropped connection or a 5xx is only the segment lost, and so is an
    /// answer that was no HTTP response at all.
    func testALostSegmentIsNotTheService() {
        for error in [
            FishSynthesisError.noResponse,
            FishSynthesisError.status(408, "timeout"),
            FishSynthesisError.status(429, "slow down"),
            FishSynthesisError.status(500, "broken"),
            FishSynthesisError.status(503, "unavailable"),
        ] {
            XCTAssertNil(error.serviceFailure(hasSynthesized: false))
        }
    }
}
