import XCTest
@testable import EidolonCore

/// 朗读 (GLOSSARY「朗读」): her line of a conversation as the voice is given it — each segment's
/// Japanese on a line of its own, with the cues the model reads and no subtitle
/// (upstream `read_aloud.py`).
final class ReadAloudTests: XCTestCase {
    private func her(_ ja: String, _ zh: String = "字幕") -> ReplySegment {
        ReplySegment(ja: ja, zh: zh)
    }

    /// Her segments go one to a line; the subtitle is not read.
    func testHerSegmentsGoOneToALineWithoutTheSubtitle() {
        let speech = ReadAloud.speech(of: [
            her("こんばんは。", "晚上好。"),
            her("[shyly] ありがとう。", "……谢谢。"),
        ], model: "drama-3")

        XCTAssertEqual(speech, "こんばんは。\n[shyly]ありがとう。")
    }

    /// The paired tags only go to the model that reads them (ADR-0004).
    func testPairedTagsOnlyGoToTheModelThatReadsThem() {
        let segments = [her("これは<whisper>内緒</whisper>だよ")]

        XCTAssertEqual(
            ReadAloud.speech(of: segments, model: "drama-3"),
            "これは<whisper>内緒</whisper>だよ"
        )
        XCTAssertEqual(
            ReadAloud.speech(of: segments, model: "s2.1-pro-free"),
            "これは内緒だよ"
        )
    }

    /// A segment with nothing to say — blank, or only a cue — is not a line of its own.
    func testSegmentsThatShowNothingAreNotLines() {
        let speech = ReadAloud.speech(of: [
            her("   "),
            her("おはよう。"),
            her("[shyly]"),
        ], model: "drama-3")

        XCTAssertEqual(speech, "おはよう。")
    }

    /// Nothing to read: no speech at all.
    func testNothingToReadIsNoSpeech() {
        XCTAssertNil(ReadAloud.speech(of: [ReplySegment](), model: "drama-3"))
        XCTAssertNil(ReadAloud.speech(of: [her(" "), her("")], model: nil))
    }

    /// 朗读按 Fish Audio 的最好音质要：请求里带着，通话那条不带（它逐段跟着说）。
    func testReadAloudAsksForFishAudiosBestQuality() throws {
        func body(_ request: FishSpeechRequest) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        }

        let read = try body(FishSpeechRequest(
            text: "おはよう。", referenceID: "voice-1", latency: ReadAloud.latency
        ))
        XCTAssertEqual(read["latency"] as? String, "normal")

        let call = try body(FishSpeechRequest(text: "おはよう。", referenceID: "voice-1"))
        XCTAssertNil(call["latency"])
    }

    /// 整句朗读比通话的一段慢得多，也没有下一段可退：上游给一分钟。
    func testReadAloudWaitsAsLongAsUpstreamDoes() {
        XCTAssertEqual(ReadAloud.timeout, 60)
    }
}

/// What one 朗读 is doing (spec #32): nothing, asking Fish Audio for it, playing it, or having
/// failed to. One line at a time; what the player and the network do with each effect is the
/// app's, so this is where the rules are tested.
final class ReadAloudPlaybackTests: XCTestCase {
    /// 点一下一条没在看的：去合成它。
    func testTappingAnIdleLineSynthesizesIt() {
        var playback = ReadAloudPlayback()

        XCTAssertEqual(playback.tap("おはよう。", isCached: false), .synthesize("おはよう。"))
        XCTAssertEqual(playback.reading, "おはよう。")
        XCTAssertEqual(playback.phase(of: "おはよう。"), .synthesizing)
    }

    /// 听过的那句再点：不用再合成。
    func testTappingACachedLinePlaysItAtOnce() {
        var playback = ReadAloudPlayback()

        XCTAssertEqual(playback.tap("おはよう。", isCached: true), .play("おはよう。"))
        XCTAssertEqual(playback.phase(of: "おはよう。"), .playing)
    }

    /// 正在放的就是这条：再点停下。
    func testTappingThePlayingLineStopsIt() {
        var playback = ReadAloudPlayback()
        _ = playback.tap("おはよう。", isCached: true)

        XCTAssertEqual(playback.tap("おはよう。", isCached: true), .stop)
        XCTAssertNil(playback.reading)
        XCTAssertNil(playback.phase)
    }

    /// 同一时间只读一条：点另一条，那条不放了，换这条去合成。
    func testTappingAnotherLineReplacesTheOnePlaying() {
        var playback = ReadAloudPlayback()
        _ = playback.tap("おはよう。", isCached: true)

        XCTAssertEqual(playback.tap("こんばんは。", isCached: false), .synthesize("こんばんは。"))
        XCTAssertEqual(playback.reading, "こんばんは。")
        XCTAssertNil(playback.phase(of: "おはよう。"))
    }

    /// 合成了：放。
    func testVoicedAudioPlays() {
        var playback = ReadAloudPlayback()
        _ = playback.tap("おはよう。", isCached: false)

        XCTAssertEqual(playback.voiced("おはよう。"), .play("おはよう。"))
        XCTAssertEqual(playback.phase(of: "おはよう。"), .playing)
    }

    /// 合成失败：这条失败着，按钮还能再点一次（重来，而不是停下）。
    func testAFailedLineCanBeTriedAgain() {
        var playback = ReadAloudPlayback()
        _ = playback.tap("おはよう。", isCached: false)

        XCTAssertEqual(playback.unvoiced("おはよう。"), .none)
        XCTAssertEqual(playback.phase(of: "おはよう。"), .failed)
        XCTAssertEqual(playback.tap("おはよう。", isCached: false), .synthesize("おはよう。"))
        XCTAssertEqual(playback.phase(of: "おはよう。"), .synthesizing)
    }

    /// 合成等回来的时候已经换了别的（或停下）：这份音频不放。
    func testAudioThatArrivesForALineNoLongerReadIsDropped() {
        var playback = ReadAloudPlayback()
        _ = playback.tap("おはよう。", isCached: false)
        _ = playback.tap("こんばんは。", isCached: false)

        XCTAssertEqual(playback.voiced("おはよう。"), .none)
        XCTAssertEqual(playback.phase(of: "こんばんは。"), .synthesizing)

        _ = playback.stop()
        XCTAssertEqual(playback.voiced("こんばんは。"), .none)
        XCTAssertNil(playback.reading)
    }

    /// 放完：回到什么都没在放。
    func testFinishingPlaybackGoesIdle() {
        var playback = ReadAloudPlayback()
        _ = playback.tap("おはよう。", isCached: true)

        XCTAssertEqual(playback.finished("おはよう。"), .none)
        XCTAssertNil(playback.reading)
        XCTAssertNil(playback.phase)
    }

    /// 进通话、离开聊天页：停下。
    func testStoppingLeavesNothingPlaying() {
        var playback = ReadAloudPlayback()
        _ = playback.tap("おはよう。", isCached: false)

        XCTAssertEqual(playback.stop(), .stop)
        XCTAssertNil(playback.reading)
        XCTAssertNil(playback.phase)
        XCTAssertEqual(playback.voiced("おはよう。"), .none)
    }
}

final class ReadAloudSceneTests: XCTestCase {
    /// 场景块只是画面，不朗读；只有场景块时没有可读的内容。
    func testSceneBlocksAreNotReadAloud() {
        let blocks: [ReplyBlock] = [
            .scene("她把杯子放下。"),
            .line(ReplySegment(ja: "……おかえり。", zh: "……欢迎回来。")),
            .scene("她别过脸。"),
        ]
        XCTAssertEqual(ReadAloud.speech(of: blocks, model: "drama-3"), "……おかえり。")
        XCTAssertNil(ReadAloud.speech(of: [.scene("她只是看着窗外。")], model: "drama-3"))
    }
}
