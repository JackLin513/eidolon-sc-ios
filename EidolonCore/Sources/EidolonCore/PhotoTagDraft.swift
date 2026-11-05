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
        let character = try characters().first { $0.id == characterID }
        let transcript = Self.photoTagTranscript(messages)
        let system = Self.photoTagPrompt(characterName: character?.name ?? "她", faceToFace: faceToFace, adult: adult)
        let user = """
            以下是最近这段对话：
            \(transcript)

            请给她的最后一条回复写一个照片标签，只输出 <photo> 标签本身。
            """
        let prompts = [
            PromptMessage(.system, system),
            PromptMessage(.user, user),
        ]
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

    private static func photoTagTranscript(_ messages: [ChatMessageRecord]) -> String {
        let recent = messages.suffix(12)
        return recent.map { message in
            if message.isFromCharacter {
                let words = message.replyBlocks.map { block -> String in
                    switch block {
                    case let .line(line): [line.ja, line.zh].filter { !$0.isEmpty }.joined(separator: " / ")
                    case let .scene(scene): "（\(scene)）"
                    }
                }.joined(separator: "\n")
                return "她：\(words)"
            }
            return "制作人：\(message.text ?? "")"
        }.joined(separator: "\n")
    }

    private static func photoTagPrompt(
        characterName: String,
        faceToFace: Bool,
        adult: Bool
    ) -> String {
        // The same words a real turn gives her, then the one difference: this answer is
        // only the tag.
        let section = PromptAssembler.photoSection(
            eligible: true,
            wants: true,
            cold: false,
            usedUp: false,
            adult: adult,
            faceToFace: faceToFace
        ) ?? ""
        return """
            # 任务
            你在替\(characterName)写一张照片的标签：不写台词，不扮演角色，不解释。
            只输出一个 <photo> 标签，标签外不要有任何文字。每栏尽量写 2–4 个 tag，
            action 写清楚正在做的事，不要只写表情。

            \(section)
            """
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

    /// The tag out of whatever the model wrote: fenced or not, with or without prose.
    static func photoTagFromAnswer(_ raw: String) throws -> PhotoTag {
        guard let open = raw.range(of: "<photo>"),
              let close = raw.range(of: "</photo>", range: open.upperBound..<raw.endIndex)
        else {
            throw PhotoTagDraftError(
                raw: raw,
                body: nil,
                detail: "模型没有写出完整的 <photo> 标签"
            )
        }
        let body = String(raw[open.upperBound..<close.lowerBound])
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
}
