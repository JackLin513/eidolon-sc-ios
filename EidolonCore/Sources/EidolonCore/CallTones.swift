import Foundation

/// 铃声, as the call holds it: the first loop's remaining time, counted from when it first
/// began to play — not where the current loop is (spec #35).
public protocol Ringback: Sendable {
    /// How much of the first loop is left; 0 when it is not playing, never played, or could
    /// not be played.
    func left() -> Duration
    func stop()
}

/// The sounds the phone itself makes (GLOSSARY.md「铃声」「接通音」「挂断音」). The engine decides
/// when each plays; the app only makes the sound.
public protocol CallTones: Sendable {
    /// Starts the ring, looping, and returns what can tell when its first loop is done.
    /// nil when it could not be played: the call then waits for nothing.
    func ring() -> (any Ringback)?
    /// Stops the ring and plays the connect tone once.
    func connect()
    /// Stops everything, plays the hang-up tone once, and waits for it to finish (no longer
    /// than the call allows); it never fails the call.
    func hangUp() async
    /// Stops everything without the hang-up tone: the call page was left, or another call
    /// is beginning.
    func silence()
}

/// Tones for a call that makes none: tests, and any caller that wants a silent call.
public struct SilentTones: CallTones {
    public init() {}

    public func ring() -> (any Ringback)? { nil }
    public func connect() {}
    public func hangUp() async {}
    public func silence() {}
}
