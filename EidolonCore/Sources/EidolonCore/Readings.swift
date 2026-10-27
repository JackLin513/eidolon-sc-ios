import Foundation

/// One entry of `characters/readings.json` (GLOSSARY.md「读音」): a name as it is written,
/// how it is read, and the phonemes Fish Audio is told. The exporter writes upstream's
/// `readings.toml` as this JSON, so the bundle carries the same dictionary the hosted
/// backend uses.
public struct Reading: Codable, Sendable, Hashable {
    /// The name as it is written: Fish Audio's key, matched as a substring, case and all.
    public var written: String
    /// How it is read, in kana.
    public var kana: String
    /// What Fish Audio is told it is read as; empty until drafted, and then not sent.
    public var phonemes: String

    public init(written: String, kana: String, phonemes: String) {
        self.written = written
        self.kana = kana
        self.phonemes = phonemes
    }
}

/// The bundle's readings file: every name that should be said as the story writes it.
public struct Readings: Sendable, Hashable {
    public var entries: [Reading]

    public init(entries: [Reading] = []) {
        self.entries = entries
    }

    /// Read the file as the exporter writes it (`{"readings": [...]}`). A missing file is
    /// no readings, as upstream reads it; a broken one is refused rather than half read.
    public init(data: Data) throws {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw ReadingsError(message: "读音文件无法解析：\(error.localizedDescription)")
        }
        var entries: [Reading] = []
        for (number, entry) in (file.readings ?? []).enumerated() {
            guard let written = entry.written, !written.isEmpty,
                  let kana = entry.kana,
                  let phonemes = entry.phonemes
            else {
                throw ReadingsError(
                    message: "读音文件的第 \(number + 1) 条应包含 written、kana、phonemes（音素还没生成时写空字符串）"
                )
            }
            entries.append(Reading(written: written, kana: kana, phonemes: phonemes))
        }
        self.init(entries: entries)
    }

    /// The entries as Fish Audio's `pronunciation_dictionary`, those with phonemes; nil when
    /// none have any (upstream `readings.pronunciation_dictionary`).
    public var pronunciationDictionary: [PronunciationDictionary]? {
        let items = entries
            .filter { !$0.phonemes.isEmpty }
            .map { PronunciationItem(key: $0.written, value: $0.phonemes, caseSensitive: true) }
        return items.isEmpty ? nil : [PronunciationDictionary(items: items)]
    }

    private struct File: Decodable {
        var readings: [Entry]?
    }

    private struct Entry: Decodable {
        var written: String?
        var kana: String?
        var phonemes: String?
    }
}

public struct ReadingsError: LocalizedError, Sendable, Equatable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// One group of Fish Audio dictionary items: `{"items": [...]}`.
public struct PronunciationDictionary: Codable, Sendable, Hashable {
    public var items: [PronunciationItem]

    public init(items: [PronunciationItem]) {
        self.items = items
    }
}

/// One name and what Fish Audio should say in its place. `case_sensitive` is always true:
/// a reading is the name as it is written.
public struct PronunciationItem: Codable, Sendable, Hashable {
    public var key: String
    public var value: String
    public var caseSensitive: Bool

    public init(key: String, value: String, caseSensitive: Bool) {
        self.key = key
        self.value = value
        self.caseSensitive = caseSensitive
    }

    enum CodingKeys: String, CodingKey {
        case key
        case value
        case caseSensitive = "case_sensitive"
    }
}

/// What Fish Audio is asked for one segment (upstream `call.FishTTS`): the Japanese as
/// written, the voice, and the readings as its pronunciation dictionary.
public struct FishSpeechRequest: Encodable, Sendable, Hashable {
    public var text: String
    public var referenceID: String
    public var format: String
    public var normalize: Bool
    public var pronunciationDictionary: [PronunciationDictionary]?

    public init(
        text: String,
        referenceID: String,
        format: String = "mp3",
        normalize: Bool = true,
        readings: Readings = Readings()
    ) {
        self.text = text
        self.referenceID = referenceID
        self.format = format
        self.normalize = normalize
        pronunciationDictionary = readings.pronunciationDictionary
    }

    enum CodingKeys: String, CodingKey {
        case text
        case referenceID = "reference_id"
        case format
        case normalize
        case pronunciationDictionary = "pronunciation_dictionary"
    }
}
