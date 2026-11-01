import Foundation

/// 朗读 (GLOSSARY「朗读」, upstream `read_aloud.py`): one reply of hers, said in her voice
/// after the fact — the whole reply in one request, at Fish Audio's best quality, because
/// nobody is waiting on a line (a call voices as she writes, a segment at a time).
public enum ReadAloud {
    /// What Fish Audio is told to say of her `segments`, voicing with `model`: each one's
    /// Japanese with the cues `model` reads, a line each; the subtitles stay on screen and a
    /// segment with nothing to say is not a line. Nil when there is nothing to read.
    public static func speech(of segments: [ReplySegment], model: String?) -> String? {
        let lines = segments.compactMap { segment -> String? in
            let shown = ReplyCues.shown(segment.ja).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shown.isEmpty else { return nil }
            let voiced = ReplyCues.spoken(ReplyCues.voiced(segment.ja), by: model)
            return voiced.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// The spoken subset of a reply: scene blocks are shown but never read aloud.
    public static func speech(of blocks: [ReplyBlock], model: String?) -> String? {
        speech(of: blocks.compactMap(\.line), model: model)
    }

    /// Fish Audio's best quality, slower to start than a call's: nobody is waiting on the line
    /// (upstream `read_aloud.LATENCY`).
    public static let latency = "normal"

    /// One whole line at best quality may take a while, and there is no next segment to fall
    /// back on (upstream `read_aloud._TIMEOUT`, connect 10s).
    public static let timeout: TimeInterval = 60
}

/// One line being read aloud and what it is doing: nothing, asking Fish Audio for it, playing
/// it, or having failed. One line at a time, and only a line that is still the one being read
/// gets its audio back. The player and the network are the app's; this is the rules.
public struct ReadAloudPlayback: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case synthesizing
        case playing
        case failed
    }

    /// What the app has to do about it: ask Fish Audio for the line, play what it has, stop
    /// what it is playing, or nothing.
    public enum Effect: Equatable, Sendable {
        case synthesize(String)
        case play(String)
        case stop
        case none
    }

    /// The line being read; none while nothing is.
    public private(set) var reading: String?
    public private(set) var phase: Phase?

    public init() {}

    public func phase(of line: String) -> Phase? {
        reading == line ? phase : nil
    }

    /// 点一下这条：没在读它就去合成（听过的那份直接放），正在读它（失败不算）就停下.
    /// A failed line is tried again rather than stopped: the user taps it once more.
    public mutating func tap(_ line: String, isCached: Bool) -> Effect {
        if reading == line, phase != .failed {
            stop()
            return .stop
        }
        reading = line
        if isCached {
            phase = .playing
            return .play(line)
        }
        phase = .synthesizing
        return .synthesize(line)
    }

    /// Fish Audio answered with audio for `line`.
    public mutating func voiced(_ line: String) -> Effect {
        guard reading == line, phase == .synthesizing else { return .none }
        phase = .playing
        return .play(line)
    }

    /// Fish Audio could not voice `line`, or what it returned could not be played; it stays
    /// the line being read, failed, to be tapped again.
    public mutating func unvoiced(_ line: String) -> Effect {
        guard reading == line, phase != nil else { return .none }
        phase = .failed
        return .none
    }

    /// What was playing got to its end.
    public mutating func finished(_ line: String) -> Effect {
        guard reading == line, phase == .playing else { return .none }
        stop()
        return .none
    }

    /// 进通话、离开聊天页、切到别的对话：停下.
    @discardableResult
    public mutating func stop() -> Effect {
        guard reading != nil else { return .none }
        reading = nil
        phase = nil
        return .stop
    }
}
