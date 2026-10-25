import Foundation

/// The names a call's recognizer is told to listen out for, as upstream's `hot_words.py`
/// does: a name said in a call should be written as the story writes it, not as another
/// word that sounds the same. They are made from what the bundle keeps—every character's
/// Japanese and Chinese name, and the world setting's units. Upstream also takes every way
/// of writing in its readings file, from which it derives surnames and Chinese given
/// names; the bundle ships no readings, so those are not made here.
public enum CallHotWords {
    /// The most characters a word with any but ASCII in it may have (upstream's limit for
    /// the speech services it supports).
    static let maxCharacters = 15
    /// The most words, split at spaces, a word all in ASCII may have.
    static let maxWords = 7

    /// The words, each once, in the order found: the Japanese names, then the Chinese
    /// names, then the units. Single characters and words the services take none of are
    /// left out: they would have ordinary words heard as names.
    public static func terms(characters: [CharacterConfig], units: [String]) -> [String] {
        var found: [String] = []
        for character in characters {
            found.append(character.name)
            if let chinese = character.nameZh, !chinese.isEmpty {
                found.append(chinese)
            }
        }
        found.append(contentsOf: units)

        var words: [String] = []
        for word in found.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard word.count > 1, fits(word), !words.contains(word) else { continue }
            words.append(word)
        }
        return words
    }

    /// Whether the services take `word` whole.
    static func fits(_ word: String) -> Bool {
        if word.allSatisfy(\.isASCII) {
            return word.split(whereSeparator: \.isWhitespace).count <= maxWords
        }
        return word.count <= maxCharacters
    }
}

extension Eidolon {
    /// The words a call's recognizer listens out for; empty when the bundle has no names.
    public func callHotWords() throws -> [String] {
        CallHotWords.terms(
            characters: try characters(),
            units: (try? loadWorld())?.units.map(\.name) ?? []
        )
    }
}
