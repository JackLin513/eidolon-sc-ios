import Foundation
import XCTest
@testable import EidolonCore

final class BailianSTTTests: XCTestCase {
    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }

    private func feed(_ json: String, into transcript: inout BailianTranscript) throws -> [SpeechUpdate] {
        try transcript.feed(Data(json.utf8))
    }

    func testTheTaskHearsChineseAndJapanese() throws {
        let message = try BailianSTTConfiguration().runTaskMessage(taskID: "task-1")
        let root = try object(message)
        let header = try XCTUnwrap(root["header"] as? [String: Any])
        XCTAssertEqual(header["action"] as? String, "run-task")
        XCTAssertEqual(header["task_id"] as? String, "task-1")
        XCTAssertEqual(header["streaming"] as? String, "duplex")
        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        XCTAssertEqual(payload["task_group"] as? String, "audio")
        XCTAssertEqual(payload["task"] as? String, "asr")
        XCTAssertEqual(payload["function"] as? String, "recognition")
        XCTAssertEqual(payload["model"] as? String, "qwen-audio-3.1-asr-flash-streaming")
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["format"] as? String, "pcm")
        XCTAssertEqual(parameters["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(parameters["vad_model"] as? String, "near_meeting_16k")
        XCTAssertEqual(parameters["language_hints"] as? [String], ["zh", "ja"])
        XCTAssertEqual(parameters["heartbeat"] as? Bool, true)
    }

    func testHotWordsAreSentAsTheTasksVocabulary() throws {
        let message = try BailianSTTConfiguration(
            hotWords: ["櫻木真乃", "L'Antica", "283"]
        ).runTaskMessage(taskID: "task-1")
        let root = try object(message)
        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        let vocabulary = try XCTUnwrap(parameters["vocabulary"] as? [String: Int])
        XCTAssertEqual(vocabulary["櫻木真乃"], 4)
        XCTAssertEqual(vocabulary["L'Antica"], 50, "Latin names are super hot words")
        XCTAssertEqual(vocabulary["283"], 4, "numbers are ordinary hot words")
    }

    func testRepeatedHotWordsDoNotDuplicate() throws {
        let vocabulary = BailianSTTConfiguration.vocabulary(for: ["田中", "田中", "L'Antica"])
        XCTAssertEqual(vocabulary, ["田中": 4, "L'Antica": 50])
    }

    func testEachRegionHasItsRealTimeAddress() {
        XCTAssertEqual(
            BailianSTTEndpoint.url(for: .beijing).absoluteString,
            "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
        )
        XCTAssertEqual(
            BailianSTTEndpoint.url(for: .singapore).absoluteString,
            "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference"
        )
    }

    func testNoVocabularyIsSentWithoutHotWords() throws {
        let message = try BailianSTTConfiguration().runTaskMessage(taskID: "task-1")
        let root = try object(message)
        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        let parameters = try XCTUnwrap(payload["parameters"] as? [String: Any])
        XCTAssertNil(parameters["vocabulary"])
    }

    func testFinishTaskNamesTheTask() throws {
        let root = try object(BailianSTTConfiguration.finishTaskMessage(taskID: "task-2"))
        let header = try XCTUnwrap(root["header"] as? [String: Any])
        XCTAssertEqual(header["action"] as? String, "finish-task")
        XCTAssertEqual(header["task_id"] as? String, "task-2")
        XCTAssertEqual(header["streaming"] as? String, "duplex")
    }

    func testASentenceIsShownAsItIsHeardAndEndsWhenItDoes() throws {
        var transcript = BailianTranscript()
        let first = try feed(
            #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"こんに","sentence_end":false}}}}"#,
            into: &transcript
        )
        XCTAssertEqual(first, [.partial("こんに")])
        let rewritten = try feed(
            #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"こんにちは","sentence_end":false}}}}"#,
            into: &transcript
        )
        XCTAssertEqual(rewritten, [.partial("こんにちは")])
        let end = try feed(
            #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"こんにちは。","sentence_end":true}}}}"#,
            into: &transcript
        )
        XCTAssertEqual(end, [.final("こんにちは。")])
    }

    func testARepeatedPartialIsNotShownAgain() throws {
        var transcript = BailianTranscript()
        let json = #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"またね","sentence_end":false}}}}"#
        XCTAssertEqual(try feed(json, into: &transcript), [.partial("またね")])
        XCTAssertEqual(try feed(json, into: &transcript), [])
    }

    func testHeartbeatsAndEmptySentencesAreNotSpeech() throws {
        var transcript = BailianTranscript()
        let heartbeat = #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"","heartbeat":true}}}}"#
        XCTAssertEqual(try feed(heartbeat, into: &transcript), [])
        let punctuation = #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"。","sentence_end":false}}}}"#
        XCTAssertEqual(try feed(punctuation, into: &transcript), [])
        let emptyEnd = #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"","sentence_end":true}}}}"#
        XCTAssertEqual(try feed(emptyEnd, into: &transcript), [.final("")])
    }

    func testTaskFinishedEndsTheStreamAndTaskFailedThrows() throws {
        var transcript = BailianTranscript()
        XCTAssertEqual(
            try feed(#"{"header":{"event":"task-finished"}}"#, into: &transcript),
            [.ended]
        )
        XCTAssertThrowsError(
            try feed(
                #"{"header":{"event":"task-failed","error_code":"InvalidParameter","error_message":"bad model"}}"#,
                into: &transcript
            )
        ) { error in
            XCTAssertEqual(
                error as? BailianError,
                .service("InvalidParameter", "bad model")
            )
        }
    }

    func testAudioIsSentInHundredMillisecondPackets() {
        var packets = BailianAudioPackets()
        XCTAssertEqual(packets.append(Data(count: 1_024)).count, 0)
        XCTAssertEqual(packets.append(Data(count: 1_024)).count, 0)
        XCTAssertEqual(packets.append(Data(count: 1_152)).count, 1)
        XCTAssertEqual(packets.append(Data(count: 3_200)).count, 1)
        let last = packets.drainPadded()
        XCTAssertNil(last, "the second packet used all the audio")
    }

    func testTheLastPartialPacketIsPaddedWithSilence() {
        var packets = BailianAudioPackets()
        _ = packets.append(Data(count: 1_000))
        let last = packets.drainPadded()
        XCTAssertEqual(last?.count, BailianSTTConfiguration.packetBytes)
        XCTAssertEqual(last?.prefix(1_000), Data(count: 1_000))
        XCTAssertEqual(last?.suffix(BailianSTTConfiguration.packetBytes - 1_000), Data(count: 2_200))
    }

    func testKeepaliveIsDueAfterASecondWithoutAudio() {
        let now = Date()
        XCTAssertFalse(BailianKeepalive.isDue(now: now, lastAudio: now.addingTimeInterval(-0.5)))
        XCTAssertTrue(BailianKeepalive.isDue(now: now, lastAudio: now.addingTimeInterval(-1)))
        XCTAssertEqual(BailianKeepalive.silence().count, BailianSTTConfiguration.packetBytes)
    }
}
