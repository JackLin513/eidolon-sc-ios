import Foundation

/// What an import is doing now, for the progress view. A package has two slow phases:
/// unpacking it and checking every file's size and CRC.
public struct ImportProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable {
        case extracting
        case validating
    }

    public var phase: Phase
    public var completed: Int
    public var total: Int

    public init(phase: Phase, completed: Int, total: Int) {
        self.phase = phase
        self.completed = min(max(completed, 0), max(total, 0))
        self.total = max(total, 0)
    }

    /// 0…1 for a determinate ProgressView; 0 when there is nothing to count.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}
