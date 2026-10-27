import Foundation

/// The time a call screen shows (upstream `callTime.ts`).
public enum CallTime: Sendable, Hashable {
    /// How long the call has lasted since it connected.
    case elapsed(seconds: Int)
    /// How long it has left before the time limit, in its last minute.
    case remaining(seconds: Int)

    public var seconds: Int {
        switch self {
        case let .elapsed(seconds), let .remaining(seconds): seconds
        }
    }
}

public enum CallClock {
    /// The time to show: elapsed, or what is left once less than a minute remains. The
    /// limit is `nil` when the call has none.
    public static func time(since: Date, limit: Duration?, now: Date) -> CallTime {
        let elapsed = max(0, Int(now.timeIntervalSince(since).rounded(.down)))
        if let limit {
            let maximum = Int(limit.inSeconds.rounded(.down))
            if maximum - elapsed < 60 {
                return .remaining(seconds: max(0, maximum - elapsed))
            }
        }
        return .elapsed(seconds: elapsed)
    }

    /// `mm:ss`, minutes going past 59 rather than to hours (upstream `clock`).
    public static func clock(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// As the screen, its note and the list show it: `03:21`, or `还剩 00:42`.
    public static func shown(_ time: CallTime) -> String {
        switch time {
        case let .elapsed(seconds): clock(seconds)
        case let .remaining(seconds): "还剩 \(clock(seconds))"
        }
    }
}
