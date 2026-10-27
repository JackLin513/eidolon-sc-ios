import Foundation
import XCTest
@testable import EidolonCore

/// A segment's emotion judged on System One (spec「情绪判断」): the state and the two
/// `choice` questions it is asked, copied verbatim from upstream `emotion.py`, and how the
/// answers are read by the family's threshold.
final class SegmentEmotionTests: XCTestCase {
    private func config(_ model: String) -> SystemOneConfig {
        SystemOneConfig(
            baseURL: URL(string: "https://judge.example/systemone")!,
            model: model,
            apiKey: "secret"
        )
    }

    /// What Jev answers a segment: probabilities by option name, in no fixed order.
    private func answers(
        emotion: [String: Double],
        nod: [String: Double]
    ) -> [String: Any] {
        [
            "emotion": ["type": "choice", "probabilities": emotion],
            "nod": ["type": "choice", "probabilities": nod],
        ]
    }

    private let feelingSatisfied: ([String: Double], [String: Double]) = (
        ["生气": 0, "难过": 0, "平静": 0, "开心": 0.45, "害羞": 0.54, "惊讶": 0.01, "思考": 0],
        ["否定": 0.02, "都不是": 0.9, "同意": 0.08]
    )

    private func judge(
        _ config: SystemOneConfig,
        recorder: RequestRecorder? = nil,
        answers: [String: Any]? = nil,
        minProbability: Double? = nil
    ) -> SystemOneSegmentEmotionJudge {
        let body = (try? systemOneBody(answers ?? [:])) ?? Data()
        return SystemOneSegmentEmotionJudge(
            config: config,
            transport: StubJudgeTransport { request in
                await recorder?.record(request)
                return (body, http(200))
            },
            minProbability: minProbability
        )
    }

    /// The segment the emotion module's tests use: the second of a reply, after one about
    /// being called cute.
    private let segment = SegmentToJudge(
        characterName: "樱木真乃",
        said: "你今天很可爱",
        before: [SaidSegment(ja: "[shyly]ほわっ……", zh: "哇……")],
        segment: SaidSegment(ja: "ありがとうございます！", zh: "谢谢！")
    )

    func testBothQuestionsAreAskedAboutTheSegmentAtOnce() async throws {
        let recorder = RequestRecorder()
        let judge = judge(
            config("typesafe/jev-1.13"),
            recorder: recorder,
            answers: answers(emotion: feelingSatisfied.0, nod: feelingSatisfied.1)
        )

        let emotion = await judge.emotion(in: segment)
        XCTAssertEqual(emotion, SegmentEmotion(emotion: .shy, nod: nil))

        let recorded = await recorder.only()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://judge.example/systemone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 1.5, "the emotion timeout caps the request")

        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.13")
        let state = try XCTUnwrap(body["state"] as? [String: Any])
        XCTAssertEqual(state["角色"] as? String, "樱木真乃")
        XCTAssertEqual(state["制作人这句话"] as? String, "你今天很可爱")
        XCTAssertEqual(state["这条回复前面几段"] as? [String], ["[shyly]ほわっ……（哇……）"])
        XCTAssertEqual(state["这一段台词"] as? String, "ありがとうございます！")
        XCTAssertEqual(state["这一段的中文字幕"] as? String, "谢谢！")

        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual(Set(questions.keys), ["emotion", "nod"])
        let emotionQuestion = try XCTUnwrap(questions["emotion"] as? [String: Any])
        XCTAssertEqual(emotionQuestion["type"] as? String, "choice")
        XCTAssertEqual(
            emotionQuestion["instructions"] as? String,
            Self.scene + "说这一段时，她脸上最主要的情绪是哪一种？"
        )
        XCTAssertEqual(
            emotionQuestion["criteria"] as? [String: String],
            [
                "平静": "普通地回应、打招呼、交代或确认事情，没有明显情绪",
                "开心": "高兴、兴奋、感激、期待",
                "害羞": "难为情、脸红、被夸或被说到心事时的不好意思",
                "惊讶": "吃惊、意外、慌张",
                "难过": "伤心、失落、寂寞、担心、不甘心",
                "生气": "不满、责怪、赌气、不能原谅",
                "思考": "在想、犹豫、斟酌措辞",
            ]
        )
        let nodQuestion = try XCTUnwrap(questions["nod"] as? [String: Any])
        XCTAssertEqual(nodQuestion["type"] as? String, "choice")
        XCTAssertEqual(
            nodQuestion["instructions"] as? String,
            Self.scene + "说这一段时，她是在对制作人的话表示同意，表示否定，还是都不是？"
        )
        XCTAssertEqual(
            nodQuestion["criteria"] as? [String: String],
            [
                "同意": "肯定、答应、附和制作人的话，会点头",
                "否定": "否认、拒绝、不同意制作人的话，会摇头",
                "都不是": "既不是同意也不是否定，例如陈述、提问、打招呼、说自己的事",
            ]
        )
    }

    func testTheFirstSegmentSaysThereIsNoneBeforeIt() {
        let state = SystemOneSegmentEmotionJudge.state(
            of: SegmentToJudge(
                characterName: "樱木真乃",
                said: "早上好",
                before: [],
                segment: SaidSegment(ja: "おはよう！", zh: "早上好！")
            )
        )
        XCTAssertEqual(state["这条回复前面几段"] as? String, "（这是回复的第一段）")
    }

    // MARK: - How the answers are read

    /// Jev's threshold is 0.5: an emotion it is less sure of leaves her calm, and a nod it
    /// is less sure of leaves her neither nodding nor shaking her head (upstream `decide`).
    func testAnAnswerBelowTheThresholdIsCalmAndNoNod() async {
        let judge = judge(
            config("typesafe/jev-1.13"),
            answers: answers(
                emotion: ["平静": 0.2, "开心": 0.45, "害羞": 0.35],
                nod: ["同意": 0.4, "否定": 0.25, "都不是": 0.35]
            )
        )
        let emotion = await judge.emotion(in: segment)
        XCTAssertEqual(emotion, SegmentEmotion(emotion: .calm, nod: nil))
    }

    /// At the threshold exactly, the answer counts.
    func testAnAnswerAtTheThresholdCounts() async {
        let judge = judge(
            config("typesafe/jev-1.13"),
            answers: answers(
                emotion: ["平静": 0.2, "开心": 0.5, "害羞": 0.3],
                nod: ["同意": 0.5, "否定": 0.25, "都不是": 0.25]
            )
        )
        let emotion = await judge.emotion(in: segment)
        XCTAssertEqual(emotion, SegmentEmotion(emotion: .happy, nod: .yes))
    }

    /// Clef and Clef-flash hear a little less surely than Jev, and are read at 0.4
    /// (upstream `JUDGE_THRESHOLDS`).
    func testEachFamilyReadsByItsOwnThreshold() async {
        let answers = answers(
            emotion: ["平静": 0.1, "开心": 0.45, "害羞": 0.45],
            nod: ["同意": 0.1, "否定": 0.1, "都不是": 0.8]
        )
        let clef = await judge(config("cloudflare/clef-flash"), answers: answers)
            .emotion(in: segment)
        XCTAssertEqual(clef, SegmentEmotion(emotion: .happy, nod: nil))
        let jev = await judge(config("typesafe/jev-1.13"), answers: answers)
            .emotion(in: segment)
        XCTAssertEqual(jev, SegmentEmotion(emotion: .calm, nod: nil))
    }

    /// The settings' minimum probability, when set, is every family's.
    func testTheSettingsMinimumOverridesEveryFamily() async {
        let judge = judge(
            config("cloudflare/clef-flash"),
            answers: answers(
                emotion: ["平静": 0.1, "开心": 0.6, "害羞": 0.3],
                nod: ["同意": 0.1, "否定": 0.1, "都不是": 0.8]
            ),
            minProbability: 0.8
        )
        let emotion = await judge.emotion(in: segment)
        XCTAssertEqual(emotion, SegmentEmotion(emotion: .calm, nod: nil))
    }

    /// A "no" nod shakes her head; "neither" is no nod at all.
    func testTheNodOptionsAreReadByName() async {
        let no = await judge(
            config("typesafe/jev-1.13"),
            answers: answers(
                emotion: ["平静": 0.9],
                nod: ["同意": 0.1, "否定": 0.8, "都不是": 0.1]
            )
        ).emotion(in: segment)
        XCTAssertEqual(no, SegmentEmotion(emotion: .calm, nod: .no))
    }

    /// An answer missing a question, naming no known option, or carrying no probabilities
    /// is no judgement at all (upstream `_read`).
    func testAnAnswerThatCannotBeReadIsNoJudgement() async {
        let unreadable: [[String: Any]] = [
            ["emotion": ["type": "choice", "probabilities": ["平静": 1.0]]],
            [
                "emotion": ["type": "choice", "probabilities": ["大哭": 1.0]],
                "nod": ["type": "choice", "probabilities": ["都不是": 1.0]],
            ],
            [
                "emotion": ["type": "noul", "noul": 0.9],
                "nod": ["type": "choice", "probabilities": ["都不是": 1.0]],
            ],
        ]
        for answers in unreadable {
            let emotion = await judge(config("typesafe/jev-1.13"), answers: answers)
                .emotion(in: segment)
            XCTAssertNil(emotion, "\(answers)")
        }
    }

    /// A service slower than the timeout leaves the segment unjudged without waiting for
    /// it (upstream `asyncio.wait_for`).
    func testASlowServiceTimesOutToNoJudgement() async throws {
        let body = try systemOneBody(answers(
            emotion: ["平静": 0.1, "开心": 0.9],
            nod: ["同意": 0.9]
        ))
        let judge = SystemOneSegmentEmotionJudge(
            config: config("typesafe/jev-1.13"),
            transport: StubJudgeTransport { _ in
                try await Task.sleep(for: .seconds(5))
                return (body, http(200))
            },
            timeout: 0.05
        )
        let clock = ContinuousClock()
        let start = clock.now
        let emotion = await judge.emotion(in: segment)
        XCTAssertNil(emotion)
        XCTAssertLessThan(
            start.duration(to: clock.now),
            .seconds(1),
            "the wait is cut at the timeout, not the service's own 5 seconds"
        )
    }

    /// A timeout, a dropped connection or a refused key leaves the segment unjudged.
    func testAFailedRequestIsNoJudgement() async {
        let failing: [@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)] = [
            { _ in throw URLError(.timedOut) },
            { _ in throw URLError(.networkConnectionLost) },
            { _ in (Data(#"{"error":{"code":"invalid_api_key","message":"bad key"}}"#.utf8), http(401)) },
            { _ in (Data(#"{"answers": {}}"#.utf8), http(200)) },
        ]
        for answer in failing {
            let judge = SystemOneSegmentEmotionJudge(
                config: config("typesafe/jev-1.13"),
                transport: StubJudgeTransport(answer: answer)
            )
            let emotion = await judge.emotion(in: segment)
            XCTAssertNil(emotion)
        }
    }

    /// Upstream `_SCENE`: the frame both questions are asked in, verbatim.
    static let scene = "角色扮演的通话中，角色是《偶像大师 闪耀色彩》283 事务所的偶像（或事务员），"
        + "正在和制作人通话。"
        + "`这一段台词` 是她此刻说出口的日语，方括号里的英文和 <whisper> 这类成对的标签是给配音的语气提示；"
        + "`这一段的中文字幕` 是这段台词的意思。"
}
