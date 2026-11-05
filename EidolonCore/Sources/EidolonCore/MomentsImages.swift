import Foundation

/// The seven pictures a moment may carry (spec #98). Three have nobody in them.
public enum MomentComposition: String, Sendable, CaseIterable, Hashable {
    case scenery
    case food
    case object
    case selfie
    case posed
    case candid
    case group

    public var title: String {
        switch self {
        case .scenery: "风景"
        case .food: "食物"
        case .object: "物品"
        case .selfie: "自拍"
        case .posed: "摆拍"
        case .candid: "抓拍"
        case .group: "合照"
        }
    }

    public var hasPeople: Bool { self != .scenery && self != .food && self != .object }

    var listedName: String { rawValue }

    static func named(_ raw: String) -> MomentComposition? {
        let value = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return Self.allCases.first { $0.rawValue == value }
            ?? [
                "风景": .scenery, "食物": .food, "物品": .object, "自拍": .selfie,
                "摆拍": .posed, "抓拍": .candid, "合照": .group,
            ][value]
    }
}

/// The `<image>` block she writes with a moment: a photo tag, plus which composition it is.
public struct MomentImageDraft: Sendable, Hashable {
    public var composition: MomentComposition
    public var shot: PhotoShot
    public var framing: PhotoFraming
    public var partner: PhotoPartner
    public var with: [String]
    public var place: [String]
    public var outfit: [String]
    public var action: [String]
    public var note: String
    public var rating: PhotoRating?

    public init(
        composition: MomentComposition, shot: PhotoShot = .other,
        framing: PhotoFraming = .upperBody, partner: PhotoPartner = .none,
        with: [String] = [], place: [String] = [], outfit: [String] = [],
        action: [String] = [], note: String = "", rating: PhotoRating? = nil
    ) {
        self.composition = composition
        self.shot = shot
        self.framing = framing
        self.partner = partner
        self.with = with
        self.place = place
        self.outfit = outfit
        self.action = action
        self.note = note
        self.rating = rating
    }

    public init?(text: String) {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "：", with: ":")
            while let first = line.first, ["-", "*", "•"].contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        func tags(_ key: String) -> [String] {
            (fields[key] ?? "")
                .replacingOccurrences(of: "，", with: ",")
                .replacingOccurrences(of: "、", with: ",")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        guard let composition = MomentComposition.named(fields["composition"] ?? "") else {
            return nil
        }
        self.init(
            composition: composition,
            shot: fields["shot"].flatMap(Self.shot) ?? (composition == .selfie ? .selfie : .other),
            framing: fields["framing"].flatMap(Self.framing) ?? .upperBody,
            partner: PhotoPartner(rawValue: fields["with"]?.lowercased() ?? "") ?? .none,
            with: tags("with"),
            place: tags("place"),
            outfit: tags("outfit"),
            action: tags("action"),
            note: fields["note"] ?? "",
            rating: fields["rating"].flatMap(Self.rating)
        )
    }

    private static func shot(_ raw: String) -> PhotoShot? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "selfie", "自拍": .selfie
        case "other", "他拍": .other
        default: nil
        }
    }

    private static func framing(_ raw: String) -> PhotoFraming? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "portrait", "肖像": .portrait
        case "upper body", "上半身": .upperBody
        case "cowboy shot", "七分身": .cowboyShot
        case "full body", "全身": .fullBody
        case "wide shot", "wide", "远景", "大远景": .wideShot
        default: nil
        }
    }

    private static func rating(_ raw: String) -> PhotoRating? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "general", "全年龄": .general
        case "sensitive", "敏感": .sensitive
        case "questionable", "可疑": .questionable
        case "explicit", "露骨": .explicit
        default: nil
        }
    }
}

extension Eidolon {
    /// Which pictures this moment may have: all seven with a picture service, only the
    /// three without people when GPT Image alone is configured, none otherwise.
    func momentAllowedCompositions(providers: MomentsProviders) -> [MomentComposition] {
        if providers.photo != nil { return MomentComposition.allCases }
        if providers.gptImage != nil, providers.gptSettings?.enabled == true {
            return [.scenery, .food, .object]
        }
        return []
    }

    /// Builds the request, or nil when the draft cannot be drawn as it is (an allowed
    /// composition can still fail: a group with nobody to stand next to her).
    func momentImageRequest(
        _ draft: MomentImageDraft,
        character: CharacterConfig,
        characters: [CharacterConfig],
        settings: ImageServiceSettings,
        adult: Bool
    ) -> ImageRequest? {
        let style = settings.style.trimmingCharacters(in: .whitespacesAndNewlines)
        let quality = ["very aesthetic", "masterpiece", "no text"]
        let fx = ["depth of field", "blurry background"]
        let width = [.scenery, .group].contains(draft.composition) ? 1216 : 832
        let height = [.scenery, .group].contains(draft.composition) ? 832 : 1216
        let rating = adult ? (draft.rating ?? .questionable) : .general
        let negative = adult ? PhotoPromptBuilder.adultNegative : PhotoPromptBuilder.allAgesNegative
        let place = draft.place.joined(separator: ", ")
        let outfit = draft.outfit.joined(separator: ", ")
        let action = draft.action.joined(separator: ", ")
        let note = draft.note

        switch draft.composition {
        case .scenery, .food, .object:
            var prompt = ["no humans"]
            if draft.composition == .scenery {
                prompt.append(contentsOf: ["scenery", "japan", "outdoors"])
            }
            if !place.isEmpty { prompt.append(place) }
            if draft.composition == .food, action.isEmpty { prompt.append("food") } else if !action.isEmpty {
                prompt.append(action)
            }
            if draft.composition == .object, action.isEmpty { return nil }
            prompt.append(contentsOf: fx)
            prompt.append(contentsOf: quality)
            prompt.append("rating:\(rating.rawValue)")
            let sceneNegative = negative + ", 1girl, 1boy, people"
            return ImageRequest(
                prompt: prompt.joined(separator: ", "),
                basePrompt: prompt.joined(separator: ", "),
                characterPrompts: [],
                negativePrompt: sceneNegative,
                width: width,
                height: height,
                model: adult ? settings.adultModel : settings.model
            )
        case .group:
            let others = draft.with.compactMap { wanted in
                characters.first {
                    $0.id == wanted || $0.name == wanted
                }
            }.filter { $0.photoTag?.isEmpty == false && !$0.photoAppearance.isEmpty }
            guard !others.isEmpty,
                  let herTag = character.photoTag, !herTag.isEmpty
            else { return nil }
            let participants = [character] + others.prefix(2)
            let subject = participants.count == 2 ? "2girls" : "3girls"
            var base = [subject]
            if draft.shot == .selfie {
                base.append("selfie")
            } else {
                base.append(participants.count == 2 ? "side-by-side" : "group picture")
            }
            if !style.isEmpty { base.append(style) }
            if !place.isEmpty { base.append(place) }
            if !outfit.isEmpty { base.append(outfit) }
            if !action.isEmpty { base.append(action) }
            base.append(contentsOf: fx)
            base.append(contentsOf: quality)
            base.append("rating:\(rating.rawValue)")
            let framing = draft.shot == .selfie
                ? (draft.framing == .portrait || draft.framing == .upperBody ? draft.framing : .upperBody)
                : draft.framing
            base.append(framing.listedName)
            let captions = participants.compactMap { person -> String? in
                guard let tag = person.photoTag, !tag.isEmpty else { return nil }
                return (["girl", tag] + person.photoAppearance).joined(separator: ", ")
            }
            return ImageRequest(
                prompt: base.joined(separator: ", "),
                basePrompt: base.joined(separator: ", "),
                characterPrompts: captions,
                negativePrompt: negative,
                width: width,
                height: height,
                model: adult ? settings.adultModel : settings.model
            )
        case .selfie, .posed, .candid:
            guard let herTag = character.photoTag, !herTag.isEmpty else { return nil }
            let appearance = character.photoAppearance
            var rest: [String] = []
            let noGaze = draft.action.contains {
                $0.contains("looking") || $0.contains("gaze") || $0.contains("eyes closed")
            }
            switch draft.composition {
            case .selfie:
                rest.append("selfie")
                if !noGaze { rest.append("looking at viewer") }
            case .posed:
                if !noGaze { rest.append("looking at viewer") }
            default:
                rest.append(noGaze ? "looking to the side" : "looking away")
            }
            var framing = draft.framing
            if draft.composition == .selfie, framing != .portrait, framing != .upperBody {
                framing = .upperBody
            }
            rest.append(framing.listedName)
            if !place.isEmpty { rest.append(place) }
            if !outfit.isEmpty { rest.append(outfit) }
            if !action.isEmpty { rest.append(action) }
            if !note.isEmpty { rest.append(note) }
            rest.append(contentsOf: fx)
            rest.append(contentsOf: quality)
            rest.append("rating:\(rating.rawValue)")
            var base = ["1girl", "solo", "idolmaster shiny colors"]
            var full = ["1girl", "solo", herTag, "idolmaster shiny colors"]
            if !style.isEmpty {
                base.append(style)
                full.append(style)
            }
            full.append(contentsOf: appearance)
            let characterCaption = (["girl", herTag] + appearance).joined(separator: ", ")
            var negativePrompt = negative
            if draft.composition == .candid {
                negativePrompt += ", looking at viewer, depth of field"
            }
            return ImageRequest(
                prompt: (full + rest).joined(separator: ", "),
                basePrompt: (base + rest).joined(separator: ", "),
                characterPrompts: [characterCaption],
                negativePrompt: negativePrompt,
                width: width,
                height: height,
                model: adult ? settings.adultModel : settings.model
            )
        }
    }

    /// Draws the picture and stores it. Nil means the post goes out as text only; the
    /// picture never holds the post back.
    func makeMomentImage(
        postID: String,
        draft: MomentImageDraft,
        character: CharacterConfig,
        characters: [CharacterConfig],
        now: Date,
        settings: MomentsSettings,
        providers: MomentsProviders,
        forceAdult: Bool = false
    ) async -> MomentImageRecord? {
        let others = draft.composition == .group
            ? draft.with.compactMap { wanted in characters.first { $0.id == wanted || $0.name == wanted } }
            : []
        let participants = [character] + others
        // No-human pictures stay all-ages and keep the normal model even in debug R
        // mode; only a picture with people in it can use the adult model.
        let adult = draft.composition.hasPeople
            && (settings.debugAdultImages || forceAdult)
            && providers.debugMode && providers.adultMode
            && participants.allSatisfy(\.isAdult)
        let allowPeople = providers.photo != nil
        if draft.composition.hasPeople, !allowPeople { return nil }

        // A group that cannot be drawn — nobody valid to stand next to her, or an OpenAI
        // image service that has no character prompts — becomes her alone, posed.
        var effective = draft
        if draft.composition == .group {
            let valid = draft.with.compactMap { wanted in
                characters.first { $0.id == wanted || $0.name == wanted }
            }.filter { $0.photoTag?.isEmpty == false && !$0.photoAppearance.isEmpty }
            if valid.isEmpty || providers.photo?.settings.apiFormat == .openai {
                effective = MomentImageDraft(
                    composition: .posed, shot: .other, framing: draft.framing,
                    place: draft.place, outfit: draft.outfit, action: draft.action,
                    note: draft.note, rating: draft.rating
                )
            }
        }

        // The no-human pictures may go to GPT Image when it is configured and on; when
        // it fails or takes too long, NovelAI draws it with the time that is left — the
        // whole picture has ten minutes, and GPT's share is at most four.
        var usedGPT = false
        if !effective.composition.hasPeople,
           let gpt = providers.gptImage, let gptSettings = providers.gptSettings,
           gptSettings.enabled {
            usedGPT = true
            let request = momentGPTRequest(effective, settings: gptSettings, now: now)
            let started = Date()
            do {
                let data = try await imageQueue.run(priority: .moment, timeout: .seconds(240)) {
                    try await gpt.generate(request, settings: gptSettings)
                }
                if let record = try? storeMomentImage(
                    postID: postID, draft: effective, data: data, now: now
                ) {
                    recordMomentImageCall(
                        request: request, provider: URL(string: gptSettings.baseURL)?.host ?? "",
                        started: started, error: nil
                    )
                    return record
                }
            } catch {
                // Fall through to NovelAI.
            }
        }
        guard let photo = providers.photo,
              let request = momentImageRequest(
                effective, character: character, characters: characters,
                settings: photo.settings, adult: adult
              )
        else { return nil }
        let started = Date()
        var data: Data?
        var failure: String?
        do {
            data = try await imageQueue.run(
                priority: .moment, timeout: .seconds(usedGPT ? 360 : 600)
            ) {
                try await photo.generator.generate(request, settings: photo.settings)
            }
        } catch {
            failure = error.localizedDescription
        }
        recordMomentImageCall(
            request: request, provider: URL(string: photo.settings.baseURL)?.host ?? "",
            started: started, error: failure
        )
        guard let data else { return nil }
        return try? storeMomentImage(
            postID: postID, draft: effective, data: data, now: now
        )
    }

    /// GPT Image takes a sentence, not a tag list (spec #98): style, the scene, the
    /// place's own name and note, her note, the tags, the month, the hour and the weather.
    func momentGPTRequest(
        _ draft: MomentImageDraft, settings: GPTImageSettings, now: Date
    ) -> ImageRequest {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.momentTokyo
        let month = calendar.component(.month, from: now)
        let hour = calendar.component(.hour, from: now)
        var pieces = [settings.style]
        switch draft.composition {
        case .scenery: pieces.append("A scenery photograph of a place in Japan with nobody in it.")
        case .food: pieces.append("A close photograph of the food on the table, nobody in the picture.")
        default: pieces.append("A close photograph of the object, nobody in the picture.")
        }
        if !draft.place.isEmpty {
            pieces.append("The place looks like this: " + draft.place.joined(separator: ", ") + ".")
        }
        if !draft.note.isEmpty { pieces.append(draft.note) }
        if !draft.action.isEmpty {
            pieces.append("Tag details: " + draft.action.joined(separator: ", ") + ".")
        }
        pieces.append("It is month \(month), around \(hour):00, in Tokyo.")
        return ImageRequest(
            prompt: pieces.joined(separator: " "),
            negativePrompt: "",
            width: [.scenery, .group].contains(draft.composition) ? 1216 : 832,
            height: [.scenery, .group].contains(draft.composition) ? 832 : 1216,
            model: settings.model
        )
    }

    private func recordMomentImageCall(
        request: ImageRequest, provider: String, started: Date, error: String?
    ) {
        let call = ServiceCall(
            at: Date(), service: .image, provider: provider,
            model: request.model, operation: .image, unit: .images,
            input: error == nil ? 1 : 0,
            latency: Date().timeIntervalSince(started), error: error, conversationID: nil
        )
        try? recordServiceCall(call)
    }

    private func storeMomentImage(
        postID: String, draft: MomentImageDraft, data: Data, now: Date
    ) throws -> MomentImageRecord {
        let id = UUID().uuidString
        let relative = "images/moments/\(id).jpg"
        let url = location.userDirectory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        let width = [.scenery, .group].contains(draft.composition) ? 1216 : 832
        let height = [.scenery, .group].contains(draft.composition) ? 832 : 1216
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_images(
                        id, post_id, file, width, height, composition, tag, note, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, postID, relative, width, height, draft.composition.rawValue,
                    draft.action.joined(separator: ", "), draft.note, Self.timestamp(now),
                ]
            )
        }
        return MomentImageRecord(
            id: id, file: relative, width: width, height: height,
            composition: draft.composition.rawValue, tag: draft.action.joined(separator: ", "),
            note: draft.note.isEmpty ? nil : draft.note
        )
    }
}
