import Foundation

/// Her sheet as every prompt reads it: upstream's file, trimmed, with our own notes
/// (Chinese name, terms) appended when a notes file sits beside the content. A character
/// without notes gets exactly upstream's sheet.
enum CharacterSheet {
    static func read(characterID: String, sheetPath: String, in directory: URL) -> String? {
        guard let contents = try? String(
            contentsOf: directory.appendingPathComponent(sheetPath), encoding: .utf8
        ) else { return nil }
        var sheet = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesURL = directory.appendingPathComponent("characters/\(characterID).notes.md")
        if let notes = try? String(contentsOf: notesURL, encoding: .utf8) {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sheet += "\n\n" + trimmed }
        }
        return sheet
    }
}
