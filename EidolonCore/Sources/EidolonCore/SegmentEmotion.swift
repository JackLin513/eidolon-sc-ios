import Foundation

/// One of her reply's segments, as the emotion judge is told it: its Japanese (delivery
/// cues and all) and its subtitle (upstream `SaidSegment`).
public struct SaidSegment: Sendable, Hashable {
    public var ja: String
    public var zh: String

    public init(ja: String, zh: String) {
        self.ja = ja
        self.zh = zh
    }
}

/// What a segment is judged by: who she is, what the producer said, the reply's segments
/// before it, and the segment itself (upstream `SegmentToJudge`).
public struct SegmentToJudge: Sendable, Hashable {
    public var characterName: String
    public var said: String
    public var before: [SaidSegment]
    public var segment: SaidSegment

    public init(
        characterName: String,
        said: String,
        before: [SaidSegment],
        segment: SaidSegment
    ) {
        self.characterName = characterName
        self.said = said
        self.before = before
        self.segment = segment
    }
}

/// How she feels saying a segment, and whether she agrees or disagrees. `nod` is nil when
/// she neither nods nor shakes her head — the answer was "neither", or it was too unsure
/// to count (upstream `decide`).
public struct SegmentEmotion: Sendable, Hashable {
    public var emotion: StandEmotion
    public var nod: StandNod.Kind?

    public init(emotion: StandEmotion, nod: StandNod.Kind? = nil) {
        self.emotion = emotion
        self.nod = nod
    }
}

/// Judges one segment's emotion during a call (spec「情绪判断」). `nil` when the segment
/// could not be judged: the service took longer than the timeout, failed, or answered
/// something unreadable. It is never asked again for that segment.
public protocol SegmentEmotionJudge: Sendable {
    func emotion(in segment: SegmentToJudge) async -> SegmentEmotion?
}

/// The judge on a System One service, asked both questions about one segment in one
/// request: her emotion and whether she agrees (upstream `ModelEmotionJudge`). Each answer
/// is read by option name, the likeliest option counting only at or above the threshold;
/// then she is calm, or neither nods nor shakes her head.
public struct SystemOneSegmentEmotionJudge: SegmentEmotionJudge {
    private let config: SystemOneConfig
    private let transport: any JudgeTransport
    /// The settings' minimum probability, over every family's when set (upstream
    /// `EmotionSettings.min_probability`).
    private let minProbability: Double?
    /// How long the segment may take to be judged before it goes unjudged (upstream
    /// `EmotionSettings.timeout`), kept inside `timeoutRange`.
    private let timeout: TimeInterval

    /// A segment's wait is long enough to reach the service and short enough to still be
    /// part of the reply. The settings check their field against the same range.
    public static let timeoutRange: ClosedRange<TimeInterval> = 0.1...10
    /// What an unusable timeout becomes.
    public static let defaultTimeout: TimeInterval = 1.5

    /// The timeout, or the default when it is not a finite number inside `timeoutRange`.
    /// `Task.sleep` traps on what a pasted field can hold (`1e30`), so it never gets one
    /// of those: this is the second line of defence behind the settings' validation.
    static func usableTimeout(_ timeout: TimeInterval) -> TimeInterval {
        timeout.isFinite && timeoutRange.contains(timeout) ? timeout : defaultTimeout
    }

    public init(
        config: SystemOneConfig,
        transport: any JudgeTransport = URLSessionJudgeTransport(),
        minProbability: Double? = nil,
        timeout: TimeInterval = 1.5
    ) {
        self.config = config
        self.transport = transport
        self.minProbability = minProbability
        self.timeout = Self.usableTimeout(timeout)
    }

    public func emotion(in segment: SegmentToJudge) async -> SegmentEmotion? {
        let provider = SystemOneJudgeProvider(config: capped(), transport: transport)
        guard let answers = await asking(provider, about: segment) else { return nil }
        return Self.read(
            answers: answers,
            threshold: minProbability ?? config.thresholds.emotion
        )
    }

    /// The request raced against the timeout, whichever finishes first: the other is
    /// cancelled. A service that takes too long leaves the segment unjudged (upstream's
    /// `asyncio.wait_for` around the judge).
    private func asking(
        _ provider: SystemOneJudgeProvider,
        about segment: SegmentToJudge
    ) async -> [String: Any]? {
        let timeout = timeout
        let answers = await withTaskGroup(of: Answers?.self) { group in
            group.addTask {
                guard let answers = try? await provider.ask(
                    state: Self.state(of: segment),
                    questions: EmotionQuestions.payload()
                ) else {
                    return nil
                }
                return Answers(values: answers)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return answers?.values
    }

    /// The answers in something that may cross the timeout's task boundary.
    private struct Answers: @unchecked Sendable {
        var values: [String: Any]
    }

    /// The configuration with the segment's timeout on it: a request may not outlive the
    /// wait, however long the service's own timeout is.
    private func capped() -> SystemOneConfig {
        var capped = config
        capped.timeout = min(config.timeout, timeout)
        return capped
    }

    /// What the judge is told of a segment: who she is, what the producer said, the
    /// reply's earlier segments each with its subtitle in parentheses, and the segment
    /// itself (upstream `ModelEmotionJudge.judge_emotion`).
    static func state(of segment: SegmentToJudge) -> [String: Any] {
        let before = segment.before.map { "\($0.ja)（\($0.zh)）" }
        let earlier: Any = before.isEmpty ? "（这是回复的第一段）" : before
        return [
            "角色": segment.characterName,
            "制作人这句话": segment.said,
            "这条回复前面几段": earlier,
            "这一段台词": segment.segment.ja,
            "这一段的中文字幕": segment.segment.zh,
        ]
    }

    /// The emotion and nod the answers say, each its likeliest option at or above
    /// `threshold`, otherwise calm and neither. Anything unreadable is no judgement at all
    /// (upstream `_read` and `decide`).
    static func read(answers: [String: Any], threshold: Double) -> SegmentEmotion? {
        guard let emotions = probabilities(
                  answers["emotion"],
                  options: EmotionQuestions.emotionOptions.map { ($0.name, $0.emotion) }
              ),
              let nods = probabilities(
                  answers["nod"],
                  options: EmotionQuestions.nodOptions.map { ($0.name, $0.nod) }
              )
        else {
            return nil
        }
        return SegmentEmotion(
            emotion: likeliest(emotions, threshold: threshold, otherwise: StandEmotion.calm),
            nod: likeliest(nods, threshold: threshold, otherwise: nil)
        )
    }

    /// Each of `options` the answer gave a probability for, in the options' own order; nil
    /// when it gave none of them.
    private static func probabilities<T>(
        _ answer: Any?,
        options: [(name: String, value: T)]
    ) -> [(value: T, probability: Double)]? {
        guard let answer = answer as? [String: Any],
              let given = answer["probabilities"] as? [String: Any]
        else {
            return nil
        }
        let read = options.compactMap { option -> (value: T, probability: Double)? in
            guard let probability = given[option.name] as? NSNumber else { return nil }
            return (option.value, probability.doubleValue)
        }
        return read.isEmpty ? nil : read
    }

    /// The likeliest option at or above `threshold`; the first one on a tie, as upstream's
    /// `max` reads them.
    private static func likeliest<T>(
        _ answers: [(value: T, probability: Double)],
        threshold: Double,
        otherwise: T
    ) -> T {
        guard let best = answers.max(by: { $0.probability < $1.probability }) else {
            return otherwise
        }
        return best.probability >= threshold ? best.value : otherwise
    }
}
