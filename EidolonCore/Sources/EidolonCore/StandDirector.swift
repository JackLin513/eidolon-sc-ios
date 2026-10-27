import Foundation

/// A segment of one of her replies in the call: which reply (from 0) and which segment of
/// it (from 0).
public struct StandSegment: Codable, Sendable, Hashable {
    public var reply: Int
    public var segment: Int

    public init(reply: Int, segment: Int) {
        self.reply = reply
        self.segment = segment
    }
}

/// A segment's emotion and nod, as the emotion judge returns them (spec「情绪判断」).
public struct StandJudgement: Codable, Sendable, Hashable {
    public var segment: StandSegment
    public var emotion: StandEmotion
    /// A nod or shake of the head that comes with the emotion.
    public var nod: StandNod.Kind?

    public init(segment: StandSegment, emotion: StandEmotion, nod: StandNod.Kind? = nil) {
        self.segment = segment
        self.emotion = emotion
        self.nod = nod
    }
}

/// What happens in a call, as far as her stand cares (the upstream `StandEvent`, less
/// what iOS does not have): who is speaking, a segment of hers starting to play, a
/// segment's emotion being judged, and the call ending.
public enum StandEvent: Sendable, Hashable {
    /// Her voice started playing.
    case botStartedSpeaking
    /// Her voice stopped playing.
    case botStoppedSpeaking
    /// The producer started speaking.
    case userStartedSpeaking
    /// The producer stopped speaking.
    case userStoppedSpeaking
    /// One of her segments started playing.
    case segmentStarted(StandSegment)
    /// The emotion judge returned a segment's emotion and nod.
    case segmentJudged(StandJudgement)
    /// The call was hung up or dropped.
    case callOver
}

/// How she should look, kept up to date from the call's events (the upstream
/// `standDirection.directStand`). A pure value: the call screen applies events and hands
/// `direction` to the renderer; the call state machine knows nothing of the stand.
///
/// - Her mouth moves while her voice plays.
/// - She looks at the producer while they speak, and nods once when they stop.
/// - Her mood follows the segment she is saying: the one her voice last started playing.
///   An emotion judged before the segment is said is kept until it is; one judged while it
///   is said is taken up at once; one judged after it has been said is dropped. Through a
///   calm segment her mood stays as it was, unless the segment opens her reply. A nod or
///   shake of the head goes with the emotion.
/// - When the call is over, all is forgotten and the next call starts calm; nods go on
///   counting, so that no two share an id.
///
/// Upstream also keeps `interruptedByTyping`; typing is not part of a call here, so nothing
/// sets it and looking is only about the producer speaking (spec「端上引擎」).
public struct StandDirector: Sendable {
    /// How she should look right now.
    public private(set) var direction: StandDirection

    /// Her voice is playing in the call.
    private var voicing = false
    /// The producer is speaking in the call.
    private var userSpeaking = false
    /// The segment she is saying, which her mood follows; `over` once it has been said.
    private var saying: Saying?
    /// Emotions judged for segments she has yet to say in this call.
    private var judged: [StandSegment: StandJudgement] = [:]
    /// How many nods she has given, to tell each one from the last.
    private var nods = 0

    private struct Saying {
        var segment: StandSegment
        /// Her voice stopped (until it starts again).
        var over: Bool
    }

    /// As a call starts.
    public init() {
        direction = .calm
    }

    /// Take in one call event.
    public mutating func apply(_ event: StandEvent) {
        switch event {
        case .botStartedSpeaking:
            voicing = true
            saying?.over = false
        case .botStoppedSpeaking:
            voicing = false
            saying?.over = true
        case .userStartedSpeaking:
            userSpeaking = true
        case .userStoppedSpeaking:
            userSpeaking = false
            nodded(.yes)
        case .segmentStarted(let at):
            startSaying(at)
        case .segmentJudged(let judgement):
            takeJudgement(judgement)
        case .callOver:
            forget()
        }
        showSpeakingAndLooking()
    }

    /// She starts saying this segment, unless she is past it already: her mood follows it
    /// if it has been judged.
    private mutating func startSaying(_ at: StandSegment) {
        if let saying, !follows(at, saying.segment) { return }
        let emotion = judged[at]
        judged = judged.filter { follows($0.key, at) }
        saying = Saying(segment: at, over: false)
        if let emotion { show(emotion) }
    }

    /// A segment's emotion is judged: kept until she says it, taken up at once while she is
    /// saying it, and dropped once it has been said.
    private mutating func takeJudgement(_ judgement: StandJudgement) {
        guard let saying else {
            judged[judgement.segment] = judgement
            return
        }
        if follows(judgement.segment, saying.segment) {
            judged[judgement.segment] = judgement
            return
        }
        if saying.over || judgement.segment.reply != saying.segment.reply { return }
        if judgement.segment.segment == saying.segment.segment { show(judgement) }
    }

    /// Her mood takes the segment's emotion, but through a calm segment it stays as it was,
    /// unless the segment opens her reply; a nod or shake of the head goes with it.
    private mutating func show(_ judgement: StandJudgement) {
        let opensReply = judgement.segment.segment == 0
        direction.mood = judgement.emotion == .calm && !opensReply
            ? direction.mood
            : judgement.emotion
        if let nod = judgement.nod { nodded(nod) }
    }

    /// Whether segment `a` comes after segment `b` in the call.
    private func follows(_ a: StandSegment, _ b: StandSegment) -> Bool {
        a.reply > b.reply || (a.reply == b.reply && a.segment > b.segment)
    }

    /// All is forgotten, but nods go on counting.
    private mutating func forget() {
        voicing = false
        userSpeaking = false
        saying = nil
        judged.removeAll()
        direction = .calm
    }

    /// Her mouth moves while her voice plays; she looks at the producer while they speak.
    private mutating func showSpeakingAndLooking() {
        direction.speaking = voicing
        direction.looking = userSpeaking
    }

    /// She nods or shakes her head, with an id no nod has had.
    private mutating func nodded(_ kind: StandNod.Kind) {
        nods += 1
        direction.nod = StandNod(kind: kind, id: nods)
    }
}
