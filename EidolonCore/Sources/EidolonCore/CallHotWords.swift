import Foundation

/// The names a call's recognizer is told to listen out for, as upstream's `hot_words.py`
/// does: a name said in a call should be written as the story writes it, not as another
/// word that sounds the same. They are made from what the bundle keeps—every reading in
/// `characters/readings.json`, each character's Chinese name and the given name inside it,
/// and the world setting's units. Lone surnames and single characters are left out: they
/// would have ordinary words heard as names.
public enum CallHotWords {
    /// The most characters a word with any but ASCII in it may have (upstream's limit for
    /// the speech services it supports).
    static let maxCharacters = 15
    /// The most words, split at spaces, a word all in ASCII may have.
    static let maxWords = 7

    /// The words, each once, in the order found: the readings, then the Chinese names,
    /// then the units. Single characters and words the services take none of are left out.
    public static func terms(
        readings: Readings = Readings(),
        characters: [CharacterConfig],
        units: [String]
    ) -> [String] {
        // Her Japanese surname is the reading that starts her full name without being it;
        // its length is how many characters the Chinese given name drops.
        let surnames = Set(
            readings.entries
                .map(\.written)
                .filter { written in
                    characters.contains { $0.name.hasPrefix(written) && $0.name != written }
                }
        )
        var found = readings.entries.map(\.written)
        for character in characters {
            // Her Japanese name, for a bundle that carries no readings (upstream's always
            // does, so this is a duplicate there and is said once).
            found.append(character.name)
            guard let chinese = character.nameZh, !chinese.isEmpty else { continue }
            found.append(chinese)
            let surnameLength = surnames
                .filter { character.name.hasPrefix($0) }
                .map(\.count)
                .max()
            if let surnameLength {
                found.append(String(chinese.dropFirst(surnameLength)))
            }
        }
        found.append(contentsOf: units)

        var words: [String] = []
        for word in found.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard word.count > 1, !surnames.contains(word), fits(word), !words.contains(word)
            else { continue }
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
            readings: (try? readings()) ?? Readings(),
            characters: try characters(),
            units: (try? loadWorld())?.units.map(\.name) ?? []
        )
    }
}
