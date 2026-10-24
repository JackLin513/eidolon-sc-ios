import Foundation

public enum ReplyLanguage: String, Codable, Sendable, Hashable {
    case ja
    case zh
}

/// One line of her reply: the Japanese she says and its Chinese subtitle.
public struct ReplySegment: Codable, Sendable, Hashable {
    public var ja: String
    public var zh: String

    public init(ja: String = "", zh: String = "") {
        self.ja = ja
        self.zh = zh
    }
}

public enum ReplyParserEvent: Sendable, Hashable {
    /// More of `segment`'s text, with delivery cues stripped for display.
    case delta(segment: Int, language: ReplyLanguage, text: String)
    /// More of `segment`'s Japanese as it is to be voiced: delivery cues kept, as the
    /// voice model is given them.
    case speechDelta(segment: Int, text: String)
}

/// Turns the model's stream into per-segment deltas, as upstream's `ReplyParser` does for
/// the `<ja>…</ja><zh>…</zh>` format. Photo tags are out of scope in v1 and are not parsed.
public struct ReplyParser: Sendable {
    public private(set) var segments: [ReplySegment] = []

    private var buffer = ""
    private var inside: ReplyLanguage?
    private var stray = ""
    private var filter = CueFilter()

    private static let jaOpen = "<ja>"
    private static let jaClose = "</ja>"
    private static let zhOpen = "<zh>"
    private static let zhClose = "</zh>"
    private static let tags = [jaOpen, jaClose, zhOpen, zhClose]

    public init() {}

    public mutating func feed(_ chunk: String) -> [ReplyParserEvent] {
        buffer += chunk
        var events: [ReplyParserEvent] = []
        while true {
            guard let language = inside else {
                guard let (index, tag, next) = nextOpenTag() else {
                    stray += drainedStray()
                    return events
                }
                let start = buffer.index(buffer.startIndex, offsetBy: index)
                stray += String(buffer[buffer.startIndex..<start])
                buffer = String(buffer[buffer.index(start, offsetBy: tag.count)...])
                if next == .ja || segments.isEmpty || !(segments.last?.zh.isEmpty ?? true) {
                    segments.append(ReplySegment())
                }
                inside = next
                filter = CueFilter()
                continue
            }

            let close = language == .ja ? Self.jaClose : Self.zhClose
            let openTag = language == .ja ? Self.jaOpen : Self.zhOpen
            if let range = buffer.range(of: close) {
                if range.lowerBound > buffer.startIndex {
                    append(language, String(buffer[buffer.startIndex..<range.lowerBound]), &events)
                }
                buffer = String(buffer[range.upperBound...])
                endLine(language, &events)
                inside = nil
            } else {
                let keep = partialSuffix(buffer, [close, openTag])
                let take = String(buffer.dropLast(keep))
                if !take.isEmpty {
                    append(language, take, &events)
                    buffer = String(buffer.suffix(keep))
                }
                return events
            }
        }
    }

    public mutating func finish() -> [ReplyParserEvent] {
        var events: [ReplyParserEvent] = []
        if let language = inside {
            let keep = partialSuffix(buffer, [language == .ja ? Self.jaClose : Self.zhClose])
            let text = String(buffer.dropLast(keep))
            if !text.isEmpty { append(language, text, &events) }
            endLine(language, &events)
        } else if segments.isEmpty, !(stray + buffer).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            append(.ja, (stray + buffer).trimmingCharacters(in: .whitespacesAndNewlines), &events)
            endLine(.ja, &events)
        }
        buffer = ""
        stray = ""
        inside = nil
        return events
    }

    // MARK: - Plumbing

    /// The earliest opening tag in the buffer, with its index and the language it opens.
    /// Anything before it is stray text, which the format says there should not be.
    private func nextOpenTag() -> (Int, String, ReplyLanguage)? {
        var found: (Int, String, ReplyLanguage)?
        for (tag, language) in [(Self.jaOpen, ReplyLanguage.ja), (Self.zhOpen, .zh)] {
            if let range = buffer.range(of: tag) {
                let index = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
                if found == nil || index < found!.0 {
                    found = (index, tag, language)
                }
            }
        }
        return found
    }

    private mutating func drainedStray() -> String {
        let keep = partialSuffix(buffer, Self.tags)
        let strayed = String(buffer.dropLast(keep))
        buffer = String(buffer.suffix(keep))
        return strayed
    }

    private mutating func append(
        _ language: ReplyLanguage,
        _ text: String,
        _ events: inout [ReplyParserEvent]
    ) {
        if segments.isEmpty { segments.append(ReplySegment()) }
        let index = segments.count - 1
        switch language {
        case .ja: segments[index].ja += text
        case .zh: segments[index].zh += text
        }
        if language == .ja, !text.isEmpty {
            events.append(.speechDelta(segment: index, text: text))
        }
        let shown = filter.feed(text)
        if !shown.isEmpty {
            events.append(.delta(segment: index, language: language, text: shown))
        }
    }

    private mutating func endLine(_ language: ReplyLanguage, _ events: inout [ReplyParserEvent]) {
        let shown = filter.finish()
        if !shown.isEmpty, !segments.isEmpty {
            events.append(.delta(segment: segments.count - 1, language: language, text: shown))
        }
        filter = CueFilter()
    }

    /// Length of the longest suffix of `text` that could be the start of one of `tags`.
    private func partialSuffix(_ text: String, _ tags: [String]) -> Int {
        let longest = tags.map(\.count).max() ?? 1
        for size in stride(from: min(text.count, longest - 1), through: 1, by: -1) {
            let suffix = String(text.suffix(size))
            if tags.contains(where: { $0.hasPrefix(suffix) }) { return size }
        }
        return 0
    }
}
