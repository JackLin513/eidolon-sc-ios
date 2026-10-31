import Foundation

/// Whose turn it is when the producer types during a call (upstream `turn_taking.py`):
/// typing while she has not started speaking it yet is a follow-on, and the reply being
/// written is dropped without a trace; typing once she has started and has a complete
/// segment interrupts her, and what she has already said is kept. This is the rule alone;
/// `CallSession` carries it out.
public enum CallTypedTurn {
    /// What the call's reply is doing when the producer types.
    public struct Reply: Equatable, Sendable {
        /// A turn is being answered and its reply has not settled.
        public var turnActive: Bool
        /// Her reply has been recorded.
        public var recorded: Bool
        /// She has started speaking it (in 只看文字, its first line has shown).
        public var startedSpeaking: Bool
        /// Segments that have all their words and subtitle.
        public var completeSegments: Int
        /// A recorded reply is still being voiced after the turn settled.
        public var stillSpeaking: Bool

        public init(
            turnActive: Bool = false,
            recorded: Bool = false,
            startedSpeaking: Bool = false,
            completeSegments: Int = 0,
            stillSpeaking: Bool = false
        ) {
            self.turnActive = turnActive
            self.recorded = recorded
            self.startedSpeaking = startedSpeaking
            self.completeSegments = completeSegments
            self.stillSpeaking = stillSpeaking
        }
    }

    public enum Action: Equatable, Sendable {
        /// No turn is under way: the typed line starts one.
        case start
        /// The reply cannot be interrupted yet: drop it without a trace, and answer the
        /// turn again with what was said plus the typed line.
        case followOn
        /// The reply can be interrupted: keep its complete segments, stop her voice, and
        /// start a new turn with the typed line.
        case interrupt
    }

    public static func action(for reply: Reply) -> Action {
        if reply.turnActive {
            let interruptible = reply.completeSegments > 0
                && (reply.startedSpeaking || reply.recorded)
            return interruptible ? .interrupt : .followOn
        }
        if reply.stillSpeaking, reply.completeSegments > 0 {
            return .interrupt
        }
        return .start
    }
}

/// Why a call's turn is being stopped: a hang-up or a follow-on drops it without a trace,
/// while an interruption keeps what she had already finished saying (upstream
/// `StopReply`). The turn reads this after it is cancelled; the call sets it before.
public final class CallTurnStop: @unchecked Sendable {
    public enum Mode: Sendable, Equatable {
        /// Nothing of the turn is recorded.
        case drop
        /// Record the first `segments` complete segments and stop.
        case keepCompleteSegments(Int)
    }

    private let lock = NSLock()
    private var mode: Mode = .drop

    public init() {}

    public func keepCompleteSegments(_ count: Int) {
        lock.lock()
        mode = .keepCompleteSegments(max(0, count))
        lock.unlock()
    }

    public func currentMode() -> Mode {
        lock.lock()
        defer { lock.unlock() }
        return mode
    }
}
