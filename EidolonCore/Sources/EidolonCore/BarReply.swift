import Foundation

/// One line of a visit: hers, in Japanese with its Chinese subtitle and how she looks
/// saying it, or the producer's, in Chinese only (upstream `BarLine`).
public struct BarLine: Sendable, Hashable {
    public enum Speaker: String, Sendable, Hashable {
        case her, producer
    }

    public var speaker: Speaker
    /// Her Chinese subtitle, or the producer's line.
    public var zh: String
    /// Her Japanese; empty for the producer.
    public var ja: String
    public var emotion: StandEmotion
    /// Whether it is a line she orders in.
    public var order: Bool

    public init(
        speaker: Speaker, zh: String, ja: String = "", emotion: StandEmotion = .calm, order: Bool = false
    ) {
        self.speaker = speaker
        self.zh = zh
        self.ja = ja
        self.emotion = emotion
        self.order = order
    }

    /// As the model wrote it, for the prompt of the calls after it.
    public func written() -> String {
        if speaker == .producer { return "<producer>\(zh)</producer>" }
        let order = order ? " order=\"true\"" : ""
        return "<her emotion=\"\(emotion.rawValue)\"\(order)><ja>\(ja)</ja><zh>\(zh)</zh></her>"
    }
}

/// Turns a stream of text chunks into the lines of a visit, each as it closes (upstream
/// `BarParser`). It forgives what it can: her line without a subtitle has its Japanese for
/// one; one without Japanese is left out, as is the producer's without words or in
/// Japanese, so the calls after it do not take after it; the producer's written with a
/// subtitle as hers are is his subtitle alone; an emotion not of the seven is calm;
/// whatever is written outside the lines is left out. A line left open as the stream ends is
/// taken as closed there.
public struct BarParser: Sendable {
    private var buffer = ""

    public init() {}

    /// The lines that closed by `chunk`.
    public mutating func feed(_ chunk: String) -> [BarLine] {
        buffer += chunk
        var lines: [BarLine] = []
        while let taken = take() {
            lines.append(taken)
        }
        return lines
    }

    /// What is left at the end of the stream: a line left open, as closed there.
    public mutating func finish() -> [BarLine] {
        let left = buffer
        buffer = ""
        guard let opening = Self.firstMatch(in: left) else { return [] }
        let speaker = left[opening.speaker] == "her" ? BarLine.Speaker.her : .producer
        let inside = Self.unclosed(String(left[opening.end...]), "</\(speaker.rawValue)>")
        guard let line = Self.line(speaker, String(left[opening.attributes]), inside) else { return [] }
        return [line]
    }

    /// The next line closed in the buffer, taken out of it; nil if none has closed yet, the
    /// buffer then holding only what may be the start of one.
    private mutating func take() -> BarLine? {
        guard let opening = Self.firstMatch(in: buffer) else {
            let cut = Self.startOfTag(buffer)
            buffer = String(buffer[buffer.index(buffer.startIndex, offsetBy: cut)...])
            return nil
        }
        let speaker = buffer[opening.speaker] == "her" ? BarLine.Speaker.her : .producer
        let close = "</\(speaker.rawValue)>"
        let start = opening.end
        guard let found = buffer.range(of: close, range: start..<buffer.endIndex) else {
            buffer = String(buffer[opening.start...])
            return nil
        }
        let inside = String(buffer[start..<found.lowerBound])
        let line = Self.line(speaker, String(buffer[opening.attributes]), inside)
        buffer = String(buffer[found.upperBound...])
        return line
    }

    // MARK: - Pattern matching over string indices

    struct Opening {
        var start: String.Index
        var end: String.Index
        var speaker: Range<String.Index>
        var attributes: Range<String.Index>
    }

    private static let opening = try! NSRegularExpression(pattern: "<(her|producer)\\b([^>]*)>")
    private static let attribute = try! NSRegularExpression(pattern: "(?<name>\\w+)\\s*=\\s*\"([^\"]*)\"")
    private static let starts = ["<her", "<producer"]
    private static let kana = try! NSRegularExpression(pattern: "[ぁ-ゖァ-ヺ]")
    private static let quoted = try! NSRegularExpression(pattern: "「[^」]*」")
    /// Characters Chinese writes often and Japanese hardly ever.
    private static let chinese = try! NSRegularExpression(pattern: "[了吗呢吧么这们你没说个还对时过让给为样什怎很晚]")

    /// The `range`th match of `pattern` in `text`: its whole range, and those of the groups.
    private static func match(
        _ pattern: NSRegularExpression, _ text: String, from start: Int = 0
    ) -> (whole: Range<String.Index>, groups: [Range<String.Index>?])? {
        let ns = text as NSString
        guard let found = pattern.firstMatch(
            in: text, range: NSRange(location: start, length: ns.length)
        ) else { return nil }
        func range(_ index: Int) -> Range<String.Index>? {
            guard index < found.numberOfRanges, found.range(at: index).location != NSNotFound else {
                return nil
            }
            return Range(found.range(at: index), in: text)
        }
        return (range(0)!, (0..<found.numberOfRanges).map(range))
    }

    private static func has(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func firstMatch(in text: String) -> Opening? {
        guard let found = match(opening, text), let speaker = found.groups[1],
              let attributes = found.groups[2] else { return nil }
        return Opening(start: found.whole.lowerBound, end: found.whole.upperBound,
                       speaker: speaker, attributes: attributes)
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        let ns = text as NSString
        for found in attribute.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let nameRange = Range(found.range(at: 1), in: text),
                  let valueRange = Range(found.range(at: 2), in: text),
                  String(text[nameRange]) == name else { continue }
            return String(text[valueRange])
        }
        return nil
    }

    /// The line written as `inside` between the tags opening with `attributes`; nil if it
    /// has no words to say.
    private static func line(_ speaker: BarLine.Speaker, _ attributes: String, _ inside: String) -> BarLine? {
        if speaker == .producer {
            let zh = inside.contains("<zh>") ? within(inside, "zh") : withoutTags(inside)
            return !zh.isEmpty && !isJapanese(zh) ? BarLine(speaker: .producer, zh: zh) : nil
        }
        let ja = within(inside, "ja")
        let zh = within(inside, "zh")
        guard !ja.isEmpty else { return nil }
        let emotion = attribute("emotion", in: attributes).flatMap(StandEmotion.init(rawValue:)) ?? .calm
        return BarLine(
            speaker: .her, zh: zh.isEmpty ? ja : zh, ja: ja, emotion: emotion,
            order: attribute("order", in: attributes) == "true"
        )
    }

    /// Whether `text` is written in Japanese: has kana but in what it quotes in 「」, and
    /// none of the characters only Chinese writes often, as a Chinese line naming her in
    /// kana has.
    private static func isJapanese(_ text: String) -> Bool {
        let unquoted = quoted.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: ""
        )
        return has(kana, unquoted) && !has(chinese, unquoted)
    }

    /// What `text` has between `<tag>` and its close, or the end of `text` if left open.
    private static func within(_ text: String, _ tag: String) -> String {
        guard let open = text.range(of: "<\(tag)>") else { return "" }
        return withoutTags(unclosed(String(text[open.upperBound...]), "</\(tag)>"))
    }

    /// `text` up to `close`, or all of it but what may be the start of `close`.
    static func unclosed(_ text: String, _ close: String) -> String {
        if let end = text.range(of: close) { return String(text[..<end.lowerBound]) }
        for size in stride(from: min(text.count, close.count - 1), through: 1, by: -1) {
            if close.hasPrefix(String(text.suffix(size))) {
                return String(text.prefix(text.count - size))
            }
        }
        return text
    }

    /// `text` without its tags, trimmed.
    static func withoutTags(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            result += rest[rest.startIndex..<open]
            if let close = rest[open...].firstIndex(of: ">") {
                rest = rest[rest.index(after: close)...]
            } else {
                // `<[^>]*?` also takes an unterminated `<` to the end.
                rest = rest[rest.endIndex...]
            }
        }
        result += rest
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where what may be the start of a line's opening tag begins at the end of `text`.
    private static func startOfTag(_ text: String) -> Int {
        guard let opens = text.lastIndex(of: "<") else { return text.count }
        let tail = String(text[opens...])
        guard !tail.contains(">") else { return text.count }
        let mayBe = starts.contains { $0.hasPrefix(tail) || tail.hasPrefix($0) }
        return mayBe ? text.distance(from: text.startIndex, to: opens) : text.count
    }
}
