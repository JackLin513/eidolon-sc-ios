import Foundation

/// Feeds a call's events to her stand (spec「通话事件」「端上引擎」): the call screen hands
/// each `CallEvent` in as it arrives and draws `direction`. The call state machine knows
/// nothing of the stand, and this is where the two meet, as pure data.
///
/// - Her mouth moves while a segment's voice plays: a segment starting to play both starts
///   that segment (so her mood follows it) and opens her mouth; its stopping shuts it.
/// - The producer speaking is read off the recognition. The first non-empty `hearing` is
///   them starting. The hearing being cleared is them stopping — it comes as soon as the
///   recognizer finalizes the words, which is the closest a call has to upstream's
///   voice-activity stop, and it may come while she is still speaking. `recognized` only
///   comes when the turn begins, which can be long after, so it is the backstop for a
///   recognizer that sends finals without partials, not the primary stop. One utterance
///   gives one nod.
/// - The call ending forgets the call; the next one starts calm.
public struct CallStandDirector: Sendable {
    /// The upstream rules, kept up to date by the events translated here. Internal so the
    /// tests can judge a segment before #33 carries the judgement in a call event.
    public internal(set) var director: StandDirector

    /// The producer is being heard: a non-empty `hearing` started it and no stop has come.
    private var producing = false
    /// Final words were heard without anything starting the producer (the recognizer sent
    /// no partials), so the `recognized` turn is where she nods.
    private var finalizedWithoutStart = false

    public init() {
        director = StandDirector()
    }

    /// How she should look right now.
    public var direction: StandDirection { director.direction }

    /// Take in one call event.
    public mutating func apply(_ event: CallEvent) {
        switch event {
        case let .hearing(text):
            if text.isEmpty {
                if producing {
                    stopProducing()
                } else {
                    finalizedWithoutStart = true
                }
            } else {
                finalizedWithoutStart = false
                guard !producing else { return }
                producing = true
                director.apply(.userStartedSpeaking)
            }
        case .recognized:
            if producing {
                stopProducing()
            } else if finalizedWithoutStart {
                // No partials: the finished turn is the whole utterance.
                director.apply(.userStoppedSpeaking)
            }
            finalizedWithoutStart = false
        case let .segmentStarted(reply, segment):
            director.apply(.segmentStarted(StandSegment(reply: reply, segment: segment)))
            director.apply(.botStartedSpeaking)
        case .segmentStopped:
            director.apply(.botStoppedSpeaking)
        case let .state(state):
            if case .ended = state {
                director.apply(.callOver)
                producing = false
                finalizedWithoutStart = false
            }
        case .segment, .failed:
            break
        }
    }

    /// The producer stopped: she stops looking and nods once.
    private mutating func stopProducing() {
        producing = false
        finalizedWithoutStart = false
        director.apply(.userStoppedSpeaking)
    }
}
