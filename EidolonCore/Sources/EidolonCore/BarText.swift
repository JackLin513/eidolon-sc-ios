import Foundation

/// A line of the bar's text box, as the page shows it (upstream `lib/barText.ts`): hers in
/// Japanese with its Chinese subtitle under it, or the producer's in Chinese alone.
public enum BarTextLine: Sendable, Hashable {
    /// Her line: the Japanese she says, and its Chinese subtitle.
    case her(ja: String, zh: String)
    /// The producer's line, in Chinese.
    case producer(zh: String)

    /// The line as it is said first: her Japanese, or the producer's Chinese.
    var main: String {
        switch self {
        case let .her(ja, _): ja
        case let .producer(zh): zh
        }
    }

    /// What her subtitle says; none for the producer's line.
    var subtitle: String? {
        switch self {
        case let .her(_, zh): zh
        case .producer: nil
        }
    }

    public var speaker: BarLine.Speaker {
        switch self {
        case .her: .her
        case .producer: .producer
        }
    }
}

/// One row of a page: the speaker's name and colon before the line's first row, and whether
/// the row is her Chinese subtitle under her Japanese.
public struct BarTextRow: Sendable, Hashable {
    /// The name and colon, where this row opens the line.
    public var name: String?
    public var text: String
    public var subtitle: Bool

    public init(name: String?, text: String, subtitle: Bool) {
        self.name = name
        self.text = text
        self.subtitle = subtitle
    }
}

/// A page of the box: at most `BarText.rowsPerPage` rows.
public struct BarTextPage: Sendable, Hashable {
    public var rows: [BarTextRow]

    public init(rows: [BarTextRow]) {
        self.rows = rows
    }
}

/// The names the box puts before a line (upstream `copy.bar.names`): hers is her name, the
/// producer's 「制作人」.
public struct BarTextNames: Sendable, Hashable {
    public var her: String
    public var producer: String

    public init(her: String, producer: String = "制作人") {
        self.her = her
        self.producer = producer
    }

    func name(of speaker: BarLine.Speaker) -> String {
        switch speaker {
        case .her: her
        case .producer: producer
        }
    }
}

/// The bar's text box (`.scratch/bar-room` spec「文本框和打字」, upstream `lib/barText.ts`): a
/// line of a visit laid out in pages of at most four rows, and how much of a page is typed out
/// by a moment.
///
/// What is laid out is measured in widths by the caller's `measure`, so the layout is the
/// same whoever draws it: the screen passes the pixel font's widths, a test counts characters.
public enum BarText {
    /// The width the text runs to: the box's 412 less 6 on either side.
    public static let width = 400
    /// The 6 the text leaves at either end inside the box: a closing mark may hang into it, and
    /// no further — past this it would be drawn outside the box.
    public static let hang = 6
    /// The box's 65 holds four rows of 16.
    public static let rowsPerPage = 4
    /// Characters typed a second (the original's one a frame at 30 frames a second).
    public static let charsPerSecond = 30

    /// `line` laid out in pages, `names` before its first row, each row measured by `measure`.
    public static func paginate(
        _ line: BarTextLine, names: BarTextNames, measure: (String) -> Int
    ) -> [BarTextPage] {
        let name = "\(names.name(of: line.speaker))："
        let main = wrapText(
            line.main, width: width, measure: measure, indent: measure(name), hang: hang
        )
            .enumerated()
            .map { index, text in BarTextRow(name: index == 0 ? name : nil, text: text, subtitle: false) }
        var rows = main
        if let subtitle = line.subtitle {
            rows += wrapText(subtitle, width: width, measure: measure, hang: hang).map {
                BarTextRow(name: nil, text: $0, subtitle: true)
            }
        }
        return stride(from: 0, to: max(rows.count, 1), by: rowsPerPage).map { start in
            BarTextPage(rows: Array(rows[min(start, rows.count)..<min(start + rowsPerPage, rows.count)]))
        }
    }

    /// `text` broken into rows `width` wide, the first `indent` in: Latin words kept whole
    /// where they fit, closing punctuation hung past the end rather than opening a row — but
    /// hung only `hang` past it, so it stays inside the box the text is drawn in.
    public static func wrapText(
        _ text: String, width: Int, measure: (String) -> Int, indent: Int = 0, hang: Int = 0
    ) -> [String] {
        var rows: [String] = []
        var row = ""
        var room = width - indent
        func breakRow() {
            rows.append(trimmedEnd(row))
            row = ""
            room = width
        }
        // Split into tokens as upstream's `TOKEN` regex does: a Latin word, a run of spaces,
        // or any other single character.
        for token in tokens(text) {
            if token.allSatisfy(\.isWhitespace) {
                if !row.isEmpty { row += " " }
                continue
            }
            if measure(row + token) <= room
                || (!row.isEmpty && hangs(token) && measure(row + token) <= width + hang)
            {
                row += token
                continue
            }
            if !trimmedEnd(row).isEmpty {
                breakRow()
            } else {
                row = ""
            }
            // A word longer than a whole row goes in a character at a time.
            for character in token {
                if !row.isEmpty, measure(row + String(character)) > room {
                    breakRow()
                }
                row.append(character)
            }
        }
        if !trimmedEnd(row).isEmpty || rows.isEmpty {
            rows.append(trimmedEnd(row))
        }
        return rows
    }

    /// When a page started typing out, and whether a tap finished it at once.
    public struct Typing: Sendable, Hashable {
        /// When it started, in seconds.
        public var startedAt: TimeInterval
        public var finished: Bool

        public init(startedAt: TimeInterval, finished: Bool = false) {
            self.startedAt = startedAt
            self.finished = finished
        }
    }

    /// The rows a page types out: her Japanese, which her subtitle keeps pace with; on a page
    /// of her subtitle alone, or of the producer's line, the text there.
    static func typedRows(_ page: BarTextPage) -> [BarTextRow] {
        let main = page.rows.filter { !$0.subtitle }
        return main.isEmpty ? page.rows : main
    }

    static func lengthOf(_ rows: [BarTextRow]) -> Int {
        rows.reduce(0) { $0 + $1.text.count }
    }

    /// How many characters of the page are typed out by `now` (all of them once tapped).
    public static func typedChars(
        _ page: BarTextPage, _ typing: Typing, now: TimeInterval
    ) -> Int {
        let length = lengthOf(typedRows(page))
        if typing.finished { return length }
        let typed = Int(((now - typing.startedAt) * Double(charsPerSecond)).rounded(.down))
        return min(length, max(0, typed))
    }

    /// When the page is typed out, unless a tap finishes it first.
    public static func typedOutAt(_ page: BarTextPage, _ typing: Typing) -> TimeInterval {
        typing.startedAt + Double((lengthOf(typedRows(page)) * 1000 + charsPerSecond - 1) / charsPerSecond) / 1000
    }

    public static func isTypedOut(
        _ page: BarTextPage, _ typing: Typing, now: TimeInterval
    ) -> Bool {
        typedChars(page, typing, now: now) == lengthOf(typedRows(page))
    }

    /// The page's rows as far as `typed` characters: the names from the start; her subtitle
    /// shown in step with her Japanese above it.
    public static func shownRows(_ page: BarTextPage, typed: Int) -> [BarTextRow] {
        let typedRows = typedRows(page)
        let length = lengthOf(typedRows)
        let pacedLength = lengthOf(page.rows.filter { !typedRows.contains($0) })
        let paced = length == 0 ? 0 : Int(((Double(min(typed, length)) / Double(length)) * Double(pacedLength)).rounded())
        var remaining: [Bool: Int] = [false: typed, true: paced]
        return page.rows.map { row in
            let key = typedRows.contains(row) ? false : true
            let count = row.text.count
            let shown = min(count, max(0, remaining[key] ?? 0))
            remaining[key, default: 0] -= shown
            var shownRow = row
            shownRow.text = String(Array(row.text).prefix(shown))
            return shownRow
        }
    }

    // MARK: - Tokens

    /// Upstream's `TOKEN`: a Latin word (letters, digits and a few marks), a run of spaces, or
    /// any other single character.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for character in text {
            if isWord(character) {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                tokens.append(word)
                word = ""
            }
            tokens.append(String(character))
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
            || "'’.,!?%-".contains(character)
    }

    /// What may hang past a row's end rather than open the next row (upstream's `CLOSING`).
    static func hangs(_ token: String) -> Bool {
        guard token.count == 1, let character = token.first else { return false }
        return "、。，．,.！？!?」』）)】〉》…ー〜～：；:;".contains(character)
    }

    /// `text` without its trailing whitespace (`trimEnd`).
    private static func trimmedEnd(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }
}

extension BarTextLine {
    /// The line as a visit's, from `BarLine`.
    init(_ line: BarLine) {
        switch line.speaker {
        case .her: self = .her(ja: line.ja, zh: line.zh)
        case .producer: self = .producer(zh: line.zh)
        }
    }
}
