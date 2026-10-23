import Foundation

/// Delivery cues are for the voice, not the reader: `[shyly]` and paired tags such as
/// `<whisper>…</whisper>` are stripped from what the screen shows, while the stored
/// segments keep them as written (upstream `delivery_cues.py`).
struct CueFilter {
    private static let pairedTags = [
        "whisper", "emphasis", "soft", "fast", "slow", "stress", "forceful",
    ]

    private var buffer = ""

    mutating func feed(_ text: String) -> String {
        buffer += text
        var shown = ""
        while true {
            guard let bracket = buffer.firstIndex(of: "[") else {
                if let open = buffer.firstIndex(of: "<"), isTagStart(buffer[open...]) {
                    shown += buffer[buffer.startIndex..<open]
                    buffer = String(buffer[open...])
                } else {
                    shown += buffer
                    buffer = ""
                }
                break
            }
            shown += buffer[buffer.startIndex..<bracket]
            buffer = String(buffer[bracket...])
            if let close = buffer.firstIndex(of: "]") {
                buffer = String(buffer[buffer.index(after: close)...])
                continue
            }
            break // the cue may continue in the next chunk
        }
        return shown
    }

    mutating func finish() -> String {
        let rest = buffer
        buffer = ""
        // A cue left open at the end was never finished; drop it rather than show it.
        if rest.hasPrefix("[") && !rest.contains("]") { return "" }
        return rest
    }

    /// Whether `text` begins with one of the paired delivery tags. A `<` that is not one
    /// (there is none in this format, but be safe) passes through.
    private func isTagStart(_ text: Substring) -> Bool {
        guard let close = text.firstIndex(of: ">") else { return false }
        var name = text[text.index(after: text.startIndex)..<close]
        if name.hasPrefix("/") { name = name.dropFirst() }
        return CueFilter.pairedTags.contains(String(name))
    }
}

/// What the reader sees: the same text without its delivery cues. Stored segments keep
/// the cues for the voice; the screen does not (upstream `delivery_cues.py`).
public enum ReplyCues {
    public static func shown(_ text: String) -> String {
        var filter = CueFilter()
        return filter.feed(text) + filter.finish()
    }
}
