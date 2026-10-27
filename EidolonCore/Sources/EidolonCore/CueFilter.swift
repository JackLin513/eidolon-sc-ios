import Foundation

/// What a line of her reply is to be said like, split from the words it is for
/// (upstream `delivery_cues.py`, ADR-0004).
///
/// A cue as the voice model reads it is English in square brackets. Drama 3 also reads
/// paired tags around the words they are for (`<whisper>内緒だよ</whisper>`), from the few
/// it knows; another voice model is given the words without them. What looks like a cue
/// written some other way (`(happy)`, `（小声で）`, `【嬉しそうに】`, `[嬉しそうに]`,
/// `<|speaker:0|>`) is dropped for everyone rather than read out as words. What people see
/// and the background models read has no cues at all.
struct CueFilter {
    static let pairedTags = [
        "whisper", "emphasis", "soft", "fast", "slow", "stress", "forceful",
    ]

    /// An opening bracket not closed within this many characters is not a cue but part of
    /// the line, and goes on as written rather than holding the line back.
    static let longestCue = 80

    private static let openers: [Character] = ["[", "(", "（", "【", "<"]

    private var held = ""
    /// Whether any of the line has been shown yet: whitespace is held until then.
    private var shownAny = false
    /// Whitespace yet to be shown.
    private var space = ""
    /// Cues and whitespace yet to be voiced.
    private var heldVoiced = ""

    /// Splits what of the line has come so far into what can be shown and what voiced,
    /// beyond what has been. A bracket is held back until it closes, so nobody sees half a
    /// cue before it goes; an opening paired tag is held until words follow it.
    mutating func feed(_ chunk: String) -> (shown: String, voiced: String) {
        held += chunk
        var shown = ""
        var voiced = ""
        while !held.isEmpty {
            let text: String
            if let opener = held.firstIndex(where: { Self.openers.contains($0) }) {
                if opener > held.startIndex {
                    text = String(held[held.startIndex..<opener])
                    held = String(held[opener...])
                } else {
                    let first = held[held.startIndex]
                    var closed: String.Index?
                    for closer in Self.closers(of: first) {
                        guard let found = held[held.index(after: held.startIndex)...]
                            .firstIndex(of: closer)
                        else { continue }
                        if closed == nil || found < closed! { closed = found }
                    }
                    if let closed {
                        let bracketed = String(held[...closed])
                        held = String(held[held.index(after: closed)...])
                        if let tag = Self.tag(bracketed) {
                            if tag.closing {
                                // A closing tag goes out with the words it closes on.
                                if shownAny { voiced += bracketed }
                            } else {
                                heldVoiced += bracketed
                            }
                        } else if Self.isCue(bracketed) {
                            heldVoiced += bracketed
                        }
                        continue
                    } else if held.count <= Self.longestCue {
                        break // wait for it to close
                    } else {
                        text = String(first)
                        held = String(held.dropFirst())
                    }
                }
            } else {
                text = held
                held = ""
            }
            let (moreShown, moreVoiced) = take(text)
            shown += moreShown
            voiced += moreVoiced
        }
        return (shown, voiced)
    }

    /// The line is over: what is left of it, a bracket that never closed as written.
    mutating func finish() -> (shown: String, voiced: String) {
        let rest = held
        held = ""
        let (shown, voiced) = take(rest)
        space = ""
        heldVoiced = ""
        return (shown, voiced)
    }

    private mutating func take(_ text: String) -> (shown: String, voiced: String) {
        var text = text
        if !shownAny {
            text = String(text.drop(while: { $0.isWhitespace }))
        }
        let body = String(text.reversed().drop(while: { $0.isWhitespace }).reversed())
        if body.isEmpty {
            space += text
            heldVoiced += text
            return ("", "")
        }
        let shown = space + body
        let voiced = heldVoiced + String(text.prefix(body.count))
        shownAny = true
        space = String(text.dropFirst(body.count))
        heldVoiced = space
        return (shown, voiced)
    }

    // MARK: - What a bracket is

    /// The characters that may close the bracket `opener` in this format.
    private static func closers(of opener: Character) -> [Character] {
        switch opener {
        case "[": ["]"]
        case "(", "（": [")", "）"]
        case "【": ["】"]
        case "<": [">"]
        default: []
        }
    }

    private struct Tag {
        var closing: Bool
    }

    /// A paired delivery tag, `<whisper>` or `</whisper>`, when `text` is exactly one.
    private static func tag(_ text: String) -> Tag? {
        guard text.hasPrefix("<"), text.hasSuffix(">"), text.count >= 3 else { return nil }
        var name = text.dropFirst().dropLast()
        let closing = name.hasPrefix("/")
        if closing { name = name.dropFirst() }
        guard pairedTags.contains(String(name)) else { return nil }
        return Tag(closing: closing)
    }

    /// A well-formed square-bracket cue: English words, spaces, commas, apostrophes and
    /// hyphens only.
    private static func isCue(_ text: String) -> Bool {
        guard text.hasPrefix("["), text.hasSuffix("]"), text.count >= 3 else { return false }
        let body = text.dropFirst().dropLast()
        guard let first = body.first, first.isASCII, first.isLetter else { return false }
        return body.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character == " " || character == ","
                    || character == "'" || character == "-")
        }
    }
}

/// What people see and what speech synthesis hears: the same text without the cues that
/// are not for it (upstream `delivery_cues.py`).
public enum ReplyCues {
    /// `text` as people see it: no cues of any kind.
    public static func shown(_ text: String) -> String {
        var filter = CueFilter()
        let (shown, _) = filter.feed(text)
        let (rest, _) = filter.finish()
        return shown + rest
    }

    /// `text` as speech synthesis hears it: the words, with its well-formed cues.
    public static func voiced(_ text: String) -> String {
        var filter = CueFilter()
        let (_, voiced) = filter.feed(text)
        let (_, rest) = filter.finish()
        return voiced + rest
    }

    /// What `voiced` is as `model` is given it: without paired tags, unless it reads them.
    public static func spoken(_ voiced: String, by model: String?) -> String {
        guard model != "drama-3" else { return voiced }
        var text = voiced
        for tag in CueFilter.pairedTags {
            text = text
                .replacingOccurrences(of: "<\(tag)>", with: "")
                .replacingOccurrences(of: "</\(tag)>", with: "")
        }
        return text
    }
}
