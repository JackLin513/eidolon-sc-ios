import Foundation

/// Where an outfit thumbnail is cached: her outfit number together with the content bundle
/// it was drawn from (spec「通话层」). The same number in a new bundle is a new picture, so
/// it is never served the old artwork.
public enum OutfitThumbnailKey {
    /// The file name, safe on disk: `stand/1030010010.png` under bundle version
    /// `2026-10-27T09:31:00Z` becomes `stand_1030010010-2026-10-27T09_31_00Z.png`.
    public static func fileName(outfitID: String, contentVersion: String) -> String {
        "\(sanitize(outfitID))-\(sanitize(contentVersion)).png"
    }

    private static func sanitize(_ value: String) -> String {
        var safe = ""
        for character in value {
            let allowed = character.isASCII
                && (character.isLetter || character.isNumber
                    || character == "-" || character == "_" || character == ".")
            safe.append(allowed ? character : "_")
        }
        return safe.isEmpty ? "current" : safe
    }
}

/// Waits for one load to report, whether it loaded or not. It ends at once when the waiting
/// card is cancelled — scrolled away — rather than holding the only off-screen renderer
/// until the timeout, and ends as failed if the page says nothing in time.
public final class LoadWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    public init() {}

    /// The load reported: true when it drew, false when it failed. Later reports do nothing.
    public func finish(_ loaded: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = loaded
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: loaded)
    }

    /// Wait for the report, the timeout, or cancellation, whichever comes first.
    public func wait(timeout: Duration) async -> Bool {
        await withTaskCancellationHandler {
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(false)
            }
            let loaded = await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
            timeoutTask.cancel()
            return loaded
        } onCancel: {
            finish(false)
        }
    }
}
