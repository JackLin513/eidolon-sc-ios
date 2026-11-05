import Foundation

public enum PhotoShot: String, Sendable, CaseIterable, Hashable {
    case selfie
    case other
}

public enum PhotoFraming: String, Sendable, CaseIterable, Hashable {
    case portrait
    case upperBody = "upper body"
    case cowboyShot = "cowboy shot"
    case fullBody = "full body"

    public var listedName: String { rawValue }
}

public enum PhotoRating: String, Sendable, CaseIterable, Hashable {
    case general
    case sensitive
    case questionable
    case explicit
}

public enum PhotoTagError: LocalizedError, Equatable {
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(detail): "照片标签不对：\(detail)"
        }
    }
}

/// The `<photo>` tag she writes at the front of a reply. It is her description of the
/// picture; the image service gets the cleaned English tags, while the whole tag stays in
/// the conversation for her to remember.
public struct PhotoTag: Sendable, Hashable {
    public var rating: PhotoRating?
    public var shot: PhotoShot
    public var framing: PhotoFraming
    public var place: [String]
    public var outfit: [String]
    public var action: [String]
    public var note: String
    /// The tag exactly as she wrote it, without the `<photo>` wrappers.
    public var raw: String

    public init(
        rating: PhotoRating? = nil,
        shot: PhotoShot,
        framing: PhotoFraming,
        place: [String],
        outfit: [String],
        action: [String],
        note: String,
        raw: String
    ) {
        self.rating = rating
        self.shot = shot
        self.framing = framing
        self.place = place
        self.outfit = outfit
        self.action = action
        self.note = note
        self.raw = raw
    }

    public init(text: String) throws {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = Self.line(String(rawLine))
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else {
                // A line of prose around the tag is not a field; ignore it.
                continue
            }
            let rawKey = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !rawKey.isEmpty else { continue }
            let key = Self.columnName(rawKey)
            let value = Self.value(
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            )
            fields[key] = value
        }
        guard !fields.isEmpty else { throw PhotoTagError.malformed("标签是空的") }
        let shot = fields["shot"].flatMap(Self.shot) ?? .selfie
        let framing = fields["framing"].flatMap(Self.framing) ?? .upperBody
        let rating = fields["rating"].flatMap(Self.rating)
        var place = Self.tags(fields["place"])
        var outfit = Self.tags(fields["outfit"])
        var action = Self.tags(fields["action"])
        guard !place.isEmpty || !outfit.isEmpty || !action.isEmpty else {
            throw PhotoTagError.malformed("place、outfit、action 不能全空")
        }
        place = Array(place.prefix(4))
        outfit = Array(outfit.prefix(4))
        action = Array(action.prefix(4))
        var total = place.count + outfit.count + action.count
        if total > 12 {
            action = Array(action.prefix(max(0, 12 - place.count - outfit.count)))
            total = place.count + outfit.count + action.count
        }
        // A selfie can be a full-body shot too: the prompt builder calls that a mirror
        // selfie, which is how it is drawn.
        self.init(
            rating: rating,
            shot: shot,
            framing: framing,
            place: place,
            outfit: outfit,
            action: action,
            note: fields["note"] ?? "",
            raw: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// One line as a field line: bullets, backticks and full-width punctuation removed,
    /// an inline `#` comment dropped.
    private static func line(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        while let first = line.first, ["-", "*", "•"].contains(first) {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        line = line.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "：", with: ":")
        if let hash = line.firstIndex(of: "#") {
            line = String(line[..<hash])
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func columnName(_ raw: String) -> String {
        switch raw {
        case "拍摄", "镜头", "shot": "shot"
        case "景别", "构图", "framing": "framing"
        case "地点", "场所", "place": "place"
        case "服装", "穿着", "outfit": "outfit"
        case "动作", "姿势", "action": "action"
        case "备注", "说明", "note": "note"
        case "尺度", "评级", "rating": "rating"
        default: raw
        }
    }

    private static func value(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        while let first = value.first, ["\"", "'"].contains(first), value.count > 1 {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        return value.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    private static func shot(_ raw: String) -> PhotoShot? {
        let value = raw.lowercased().replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        switch value {
        case "selfie", "自拍", "自拍照", "self portrait", "self shot": return .selfie
        case "other", "他拍", "别人拍", "他人拍", "third person": return .other
        default: return nil
        }
    }

    private static func framing(_ raw: String) -> PhotoFraming? {
        let value = raw.lowercased().replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        switch value {
        case "portrait", "肖像", "特写": return .portrait
        case "upper body", "上半身", "半身": return .upperBody
        case "cowboy shot", "cowboy", "七分身", "牛仔镜头": return .cowboyShot
        case "full body", "fullbody", "全身": return .fullBody
        default: return nil
        }
    }

    private static func rating(_ raw: String) -> PhotoRating? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "general", "全年龄": return .general
        case "sensitive", "敏感": return .sensitive
        case "questionable", "可疑": return .questionable
        case "explicit", "露骨": return .explicit
        default: return nil
        }
    }

    /// The tag as it goes back into her history, so a later turn sees what she wrote.
    public var serialized: String {
        "<photo>\n\(raw)\n</photo>"
    }

    /// Cleans the three tag columns and applies the table. In all-ages mode every blocked
    /// category is removed; in adult mode appearance, style and people still are.
    public func sanitized(using table: PhotoTagTable, adult: Bool) -> PhotoTag {
        var cleaned = self
        cleaned.place = Self.clean(place, table: table, adult: adult, fallback: "indoors")
        cleaned.outfit = Self.clean(outfit, table: table, adult: adult, fallback: "casual")
        cleaned.action = Self.clean(action, table: table, adult: adult, fallback: "smile")
        cleaned.rating = adult
            ? (rating ?? .questionable)
            : .general
        return cleaned
    }

    private static func clean(
        _ tags: [String],
        table: PhotoTagTable,
        adult: Bool,
        fallback: String
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for original in tags {
            let tag = normalized(original)
            guard !tag.isEmpty else { continue }
            if let category = table.blockingCategory(of: tag) {
                let alwaysBlocked = category == .appearance || category == .style || category == .people
                if !adult || alwaysBlocked { continue }
            }
            let rewritten = table.rewrites[tag] ?? tag
            guard seen.insert(rewritten).inserted else { continue }
            result.append(rewritten)
            if result.count == 4 { break }
        }
        return result.isEmpty ? [fallback] : result
    }

    private static func normalized(_ text: String) -> String {
        var value = text.lowercased()
            .replacingOccurrences(of: "_", with: " ")
        for character in ["{", "}", "[", "]", "::", "|", "#", "\"", "'"] {
            value = value.replacingOccurrences(of: character, with: "")
        }
        value = value.replacingOccurrences(of: "text:", with: "")
        value = value.replacingOccurrences(of: "  ", with: " ")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tags(_ text: String?) -> [String] {
        guard let text else { return [] }
        let unified = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
        return unified.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
}

public enum PhotoPromptBuilder {
    public static let allAgesNegative = """
        nsfw, @_@, mismatched pupils, glowing eyes, bad anatomy, nude, nipples, underwear, \
        bra, panties, bra strap, strap slip, see-through, pantyshot, cleavage
        """

    public static let adultNegative = """
        lowres, bad anatomy, bad hands, text, watermark, child, loli, shota, toddler, aged down
        """

    public static func request(
        tag: PhotoTag,
        character: CharacterConfig,
        style: String,
        adult: Bool,
        table: PhotoTagTable,
        model: String
    ) throws -> ImageRequest {
        guard let characterTag = character.photoTag,
              !characterTag.isEmpty,
              !character.photoAppearance.isEmpty
        else { throw PhotoTagError.malformed("这位角色没有照片 tag 或外貌 tag") }
        let cleaned = tag.sanitized(using: table, adult: adult)
        var prompt: [String] = [
            "1girl",
            "solo",
            characterTag,
            "idolmaster shiny colors",
        ]
        let trimmedStyle = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStyle.isEmpty { prompt.append(trimmedStyle) }
        prompt.append(character.photoAppearance.joined(separator: ", "))
        // Her words may already say where she is looking (at the camera, away, down):
        // do not add a second gaze that contradicts them.
        let gaze = cleaned.action.contains { $0.contains("looking") || $0.contains("gaze") }
            ? ""
            : ", looking at viewer"
        if cleaned.shot == .selfie {
            // A full-body selfie is drawn as a mirror selfie; an arm-length one is not.
            let far = cleaned.framing == .cowboyShot || cleaned.framing == .fullBody
            prompt.append((far ? "mirror selfie" : "selfie") + gaze)
        } else if !gaze.isEmpty {
            prompt.append("looking at viewer")
        }
        prompt.append(cleaned.framing.listedName)
        prompt.append(cleaned.place.joined(separator: ", "))
        prompt.append(cleaned.outfit.joined(separator: ", "))
        prompt.append(cleaned.action.joined(separator: ", "))
        prompt.append("rating:\(cleaned.rating?.rawValue ?? "general")")
        prompt.append(contentsOf: ["very aesthetic", "masterpiece", "no text"])
        return ImageRequest(
            prompt: prompt.joined(separator: ", "),
            negativePrompt: adult ? adultNegative : allAgesNegative,
            width: PhotoGeometry.width,
            height: PhotoGeometry.height,
            model: model
        )
    }
}
