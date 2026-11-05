import Foundation

/// A photo tag the debug page asked the chat model to draft, with what it wrote.
public struct PhotoTagDraft: Sendable {
    public var tag: PhotoTag
    public var raw: String
}

/// A draft that did not parse: what the model wrote, the tag body if one was found, and
/// why it failed, so the debug page can show it and the producer can fix it.
public struct PhotoTagDraftError: LocalizedError, Sendable {
    public var raw: String
    public var body: String?
    public var detail: String

    public var errorDescription: String? { detail }
}

extension Eidolon {
    /// Development aid: the same chat model a turn uses, asked only for a photo tag for
    /// the latest reply. It is not a turn: nothing is written to the conversation, but the
    /// model call is kept in the usage ledger. The answer is parsed with the same
    /// `PhotoTag` rules, so a malformed one fails here rather than at generation.
    public func draftPhotoTag(
        characterID: String,
        conversationID: String?,
        messages: [ChatMessageRecord],
        faceToFace: Bool,
        adult: Bool,
        provider: any ChatProvider,
        now: Date = Date()
    ) async throws -> PhotoTagDraft {
        guard let character = try characters().first(where: { $0.id == characterID }) else {
            throw PhotoTagDraftError(raw: "", body: nil, detail: "找不到角色 \(characterID)")
        }
        let producer = try producerProfile()
        let zone = producer.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        // The same prompt a real turn gets, with the producer asking for a picture at the
        // end: she answers in her own voice and writes the tag the way she always does.
        // A tag-only prompt made the model describe the scene instead of tagging it.
        let nowText = NowPrompt.text(
            now: now,
            timeZone: zone,
            talking: faceToFace ? .inPerson : .typing,
            affinityLines: [],
            lastContact: nil,
            birthday: producer.birthday
        )
        let photoSection = PromptAssembler.photoSection(
            eligible: true,
            wants: true,
            cold: false,
            usedUp: false,
            adult: adult,
            faceToFace: faceToFace
        ) ?? ""
        let assembler = PromptAssembler(
            bundleDirectory: location.contentDirectory,
            character: character,
            world: try loadWorld(),
            producer: producer,
            today: Self.isoDay(now, in: zone),
            nowSection: [nowText, photoSection].joined(separator: "\n\n"),
            formatInstructions: ReplyFormatInstructions.text,
            adultMode: adult,
            affinityTier: (try? readAffinity(characterID: characterID, now: now))?.tier ?? .trust
        )
        // Her old tags are left out of the history: this model copies any tag it can
        // see, and the draft came out as the previous photo every time.
        let history = messages.map { message in
            var stored = Self.storedMessage(message)
            if stored.photoTag != nil {
                stored.photoTag = nil
                stored.photoFailed = false
            }
            return stored
        }
        var prompts = try assembler.prompt(
            history: history,
            text: faceToFace ? "（把手机举起来）让我拍一张。" : "现在拍张照片给我。"
        )
        prompts.append(PromptMessage(.system, Self.photoTagRules(lastAsked: messages.last(where: { $0.role == "user" })?.text)))
        var raw = ""
        for try await delta in provider.stream(messages: prompts) {
            raw += delta
        }
        try Task.checkCancellation()
        do {
            let tag = try Self.photoTagFromAnswer(raw)
            Self.logDraft(raw, error: nil, in: location.userDirectory)
            await recordChatCall(
                provider: provider,
                operation: .chatText,
                prompts: [prompts],
                output: raw,
                latency: nil,
                error: nil,
                conversationID: conversationID,
                at: now
            )
            return PhotoTagDraft(tag: tag, raw: raw)
        } catch {
            // A draft that fails still cost a call, and its answer is worth keeping.
            Self.logDraft(raw, error: error.localizedDescription, in: location.userDirectory)
            await recordChatCall(
                provider: provider,
                operation: .chatText,
                prompts: [prompts],
                output: raw,
                latency: nil,
                error: error.localizedDescription,
                conversationID: conversationID,
                at: now
            )
            throw error
        }
    }

    /// The one difference from a real turn: this answer is only the tag. Everything
    /// before it is the prompt she would really get, so the tags come from the scene
    /// rather than from a tag-writing persona.
    private static func photoTagRules(lastAsked: String?) -> String {
        var rules = """
            # 这一回合只写照片标签
            只输出一个 <photo> 标签，标签外不要写任何文字，也不要写台词。
            按对话最后一轮制作人的要求和此刻正在发生的事写：
            - shot：他拿手机或相机拍你写 other；他要自拍才写 selfie。
            - framing：他说“全身”就写 full body，说“上半身/特写”就写 upper body，没指定再自己选。
            - place：地点 + 1–2 个看得见的道具或背景，再写光线；时间按「此刻」那段写，
              不要沿用历史里的时间；只写 office 太空，写成 office, desk, window, sunlight。
            - outfit：此刻的穿着或裸露状态，写到“脱到哪一步”（例如 white blouse untucked,
              black skirt hiked up, topless, completely nude, panties around one leg）。
            - action：此刻具体的姿势、表情、身体状态，写 3–5 个常见英文 Danbooru tag
              （例如 lying on back, legs spread, back arched, mouth open, sweat）。
              闭眼写 eyes closed；没看镜头写 facing viewer 或 looking to the side，
              不要写 looking away（已废弃）。
            不要照抄历史里的任何照片标签；以此刻为准。
            """
        if let lastAsked, !lastAsked.isEmpty {
            let quoted = lastAsked.count > 160 ? String(lastAsked.prefix(160)) : lastAsked
            rules += "\n制作人刚才说的是：「\(quoted)」。framing 和地点要按这句话里的要求写。"
        }
        return rules
    }

    private static func storedMessage(_ message: ChatMessageRecord) -> StoredMessage {
        StoredMessage(
            id: message.id,
            role: message.role,
            text: message.text,
            segments: message.segments,
            blocks: message.blocks,
            createdAt: message.createdAt,
            photoTag: message.photoTag
        )
    }

    /// The debug page's drafts, kept in the user directory so a bad one can be read back
    /// from the Mac: never uploaded, and not part of the library.
    private static func logDraft(_ raw: String, error: String?, in directory: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp)\n\(raw)\n--- \(error ?? "ok") ---\n\n"
        let url = directory.appendingPathComponent("photo-drafts.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }

    /// The tag out of whatever the model wrote: fenced or not, with or without prose, and
    /// with or without the closing tag (a reply that ran straight into its dialogue).
    static func photoTagFromAnswer(_ raw: String) throws -> PhotoTag {
        guard let open = raw.range(of: "<photo>") else {
            throw PhotoTagDraftError(
                raw: raw,
                body: nil,
                detail: "模型没有写出 <photo> 标签"
            )
        }
        let rest = raw[open.upperBound...]
        let body = rest.range(of: "</photo>").map {
            String(rest[..<$0.lowerBound])
        } ?? Self.fieldLines(String(rest))
        do {
            return try PhotoTag(text: body)
        } catch {
            throw PhotoTagDraftError(
                raw: raw,
                body: body,
                detail: error.localizedDescription
            )
        }
    }

    /// Without a closing tag, the tag is the run of `key: value` lines that follows it;
    /// the reply's own words start after them.
    private static func fieldLines(_ text: String) -> String {
        var kept: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("<") { break }
            guard trimmed.contains(":") || trimmed.contains("：") else { break }
            kept.append(String(line))
        }
        return kept.joined(separator: "\n")
    }
}
