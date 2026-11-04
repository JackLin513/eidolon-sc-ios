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

    public var isEmpty: Bool {
        ja.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One ordered piece of her reply: a spoken line (Japanese with its subtitle) or a scene
/// block (Chinese description that is shown but never voiced). Blocks keep the order the
/// model wrote them in, so a scene can come before, between, or after lines.
public enum ReplyBlock: Codable, Sendable, Hashable {
    case line(ReplySegment)
    case scene(String)

    public var line: ReplySegment? {
        if case let .line(line) = self { return line }
        return nil
    }

    public var scene: String? {
        if case let .scene(scene) = self { return scene }
        return nil
    }

    public var isEmpty: Bool {
        switch self {
        case let .line(line): line.isEmpty
        case let .scene(scene):
            scene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case line
        case scene
    }

    private enum Kind: String, Codable {
        case line
        case scene
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .line:
            self = .line(try container.decode(ReplySegment.self, forKey: .line))
        case .scene:
            self = .scene(try container.decode(String.self, forKey: .scene))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .line(line):
            try container.encode(Kind.line, forKey: .kind)
            try container.encode(line, forKey: .line)
        case let .scene(scene):
            try container.encode(Kind.scene, forKey: .kind)
            try container.encode(scene, forKey: .scene)
        }
    }
}

public enum ReplyParserEvent: Sendable, Hashable {
    /// More of a line's text, with delivery cues stripped for display.
    case delta(block: Int, language: ReplyLanguage, text: String)
    /// More of a line's Japanese as it is to be voiced: delivery cues kept, as the voice
    /// model is given them.
    case speechDelta(block: Int, text: String)
    /// More of a scene block's Chinese description; never voiced.
    case sceneDelta(block: Int, text: String)
    /// The `<photo>` tag that opened a reply, once it has closed and parsed.
    case photoTag(PhotoTag)
}

/// Turns the model's stream into per-block deltas, as upstream's `ReplyParser` does for
/// the `<ja>…</ja><zh>…</zh>` format, plus this repository's `<scene>…</scene>` blocks.
public struct ReplyParser: Sendable {
    /// Every block, in the order it was written. Empty line and scene blocks are left in
    /// while streaming and filtered by the caller when the reply is recorded.
    public private(set) var blocks: [ReplyBlock] = []

    /// Just the spoken lines, in order: what read-aloud, judgement, memory and the legacy
    /// columns use.
    public var segments: [ReplySegment] {
        blocks.compactMap(\.line)
    }

    private enum Inside {
        case ja(Int)
        case zh(Int)
        case scene(Int)
        case photo

        var closeTag: String {
            switch self {
            case .ja: ReplyParser.jaClose
            case .zh: ReplyParser.zhClose
            case .scene: ReplyParser.sceneClose
            case .photo: ReplyParser.photoClose
            }
        }
    }

    /// The tag an opening tag opens, before it has a block.
    private enum OpenTag {
        case ja
        case zh
        case scene
        case photo
    }

    private var buffer = ""
    private var inside: Inside?
    private var stray = ""
    private var filter = CueFilter()
    private var photoBuffer = ""
    private var capturePhoto = false
    private var photoSeen = false

    private static let jaOpen = "<ja>"
    private static let jaClose = "</ja>"
    private static let zhOpen = "<zh>"
    private static let zhClose = "</zh>"
    private static let sceneOpen = "<scene>"
    private static let sceneClose = "</scene>"
    private static let photoOpen = "<photo>"
    private static let photoClose = "</photo>"
    private static let tags = [
        jaOpen, jaClose, zhOpen, zhClose, sceneOpen, sceneClose, photoOpen, photoClose,
    ]

    public init() {}

    public mutating func feed(_ chunk: String) -> [ReplyParserEvent] {
        buffer += chunk
        var events: [ReplyParserEvent] = []
        while true {
            guard let inside else {
                guard let (index, tag, next) = nextOpenTag() else {
                    stray += drainedStray()
                    return events
                }
                let start = buffer.index(buffer.startIndex, offsetBy: index)
                stray += String(buffer[buffer.startIndex..<start])
                buffer = String(buffer[buffer.index(start, offsetBy: tag.count)...])
                switch next {
                case .ja:
                    let block = blocks.count
                    blocks.append(.line(ReplySegment()))
                    self.inside = .ja(block)
                case .zh:
                    let block = lineBlockForSubtitle()
                    self.inside = .zh(block)
                case .scene:
                    let block = blocks.count
                    blocks.append(.scene(""))
                    self.inside = .scene(block)
                case .photo:
                    capturePhoto = !photoSeen
                        && blocks.isEmpty
                        && stray.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if capturePhoto {
                        photoSeen = true
                        photoBuffer = ""
                    }
                    self.inside = .photo
                }
                filter = CueFilter()
                continue
            }

            let close = inside.closeTag
            if let range = buffer.range(of: close) {
                if range.lowerBound > buffer.startIndex {
                    append(
                        inside,
                        String(buffer[buffer.startIndex..<range.lowerBound]),
                        &events
                    )
                }
                buffer = String(buffer[range.upperBound...])
                endBlock(inside, &events)
                self.inside = nil
            } else {
                let keep = partialSuffix(
                    buffer,
                    [close, Self.jaOpen, Self.zhOpen, Self.sceneOpen, Self.photoOpen]
                )
                let take = String(buffer.dropLast(keep))
                if !take.isEmpty {
                    append(inside, take, &events)
                    buffer = String(buffer.suffix(keep))
                }
                return events
            }
        }
    }

    public mutating func finish() -> [ReplyParserEvent] {
        var events: [ReplyParserEvent] = []
        if let inside {
            let keep = partialSuffix(buffer, [inside.closeTag])
            let text = String(buffer.dropLast(keep))
            if !text.isEmpty { append(inside, text, &events) }
            endBlock(inside, &events)
        } else if blocks.isEmpty {
            let text = (stray + buffer)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let block = blocks.count
                blocks.append(.line(ReplySegment()))
                // The untagged reply is a line with no tags, so it goes through the same
                // cue filter as one: what people see has no cues, what is voiced keeps them.
                append(.ja(block), text, &events)
                endBlock(.ja(block), &events)
            }
        }
        buffer = ""
        stray = ""
        inside = nil
        return events
    }

    // MARK: - Blocks

    /// A `<zh>` without a line of its own still needs a line block; if the previous block
    /// is a line whose subtitle has not started, this is that line's subtitle.
    private mutating func lineBlockForSubtitle() -> Int {
        if let last = blocks.indices.last, case let .line(line) = blocks[last], line.zh.isEmpty {
            return last
        }
        let block = blocks.count
        blocks.append(.line(ReplySegment()))
        return block
    }

    private mutating func append(
        _ inside: Inside,
        _ text: String,
        _ events: inout [ReplyParserEvent]
    ) {
        switch inside {
        case let .ja(block):
            guard case var .line(line) = blocks[block] else { return }
            line.ja += text
            blocks[block] = .line(line)
            let (shown, voiced) = filter.feed(text)
            if !shown.isEmpty {
                events.append(.delta(block: block, language: .ja, text: shown))
            }
            if !voiced.isEmpty {
                events.append(.speechDelta(block: block, text: voiced))
            }
        case let .zh(block):
            guard case var .line(line) = blocks[block] else { return }
            line.zh += text
            blocks[block] = .line(line)
            // Subtitles are not voiced and carry no delivery cues.
            events.append(.delta(block: block, language: .zh, text: text))
        case let .scene(block):
            guard case var .scene(scene) = blocks[block] else { return }
            // Scene blocks are shown without delivery cues too; they are never voiced.
            let (shown, _) = filter.feed(text)
            scene += shown
            blocks[block] = .scene(scene)
            if !shown.isEmpty {
                events.append(.sceneDelta(block: block, text: shown))
            }
        case .photo:
            if capturePhoto { photoBuffer += text }
        }
    }

    private mutating func endBlock(
        _ inside: Inside,
        _ events: inout [ReplyParserEvent]
    ) {
        switch inside {
        case let .ja(block):
            let (shown, voiced) = filter.finish()
            if !shown.isEmpty {
                events.append(.delta(block: block, language: .ja, text: shown))
            }
            if !voiced.isEmpty {
                events.append(.speechDelta(block: block, text: voiced))
            }
            filter = CueFilter()
        case let .scene(block):
            let (shown, _) = filter.finish()
            if case var .scene(scene) = blocks[block] {
                scene += shown
                blocks[block] = .scene(scene)
            }
            if !shown.isEmpty {
                events.append(.sceneDelta(block: block, text: shown))
            }
            filter = CueFilter()
        case .zh:
            break
        case .photo:
            if capturePhoto, let tag = try? PhotoTag(text: photoBuffer) {
                events.append(.photoTag(tag))
            }
            photoBuffer = ""
            capturePhoto = false
        }
    }

    // MARK: - Plumbing

    /// The earliest opening tag in the buffer, with its index and the block it opens.
    /// Anything before it is stray text, which the format says there should not be.
    private func nextOpenTag() -> (Int, String, OpenTag)? {
        var found: (Int, String, OpenTag)?
        for (tag, block) in [
            (Self.jaOpen, OpenTag.ja),
            (Self.zhOpen, OpenTag.zh),
            (Self.sceneOpen, OpenTag.scene),
            (Self.photoOpen, OpenTag.photo),
        ] {
            if let range = buffer.range(of: tag) {
                let index = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
                if found == nil || index < found!.0 {
                    found = (index, tag, block)
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
