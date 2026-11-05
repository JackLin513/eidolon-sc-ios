import Foundation

/// A photo tag the debug page asked the chat model to draft, with what it wrote.
public struct PhotoTagDraft: Sendable {
    public var tag: PhotoTag
    public var raw: String
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
        let tag = try Self.photoTagFromAnswer(raw)
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

    private static func photoTagPrompt(characterName: String, faceToFace: Bool, adult: Bool) -> String {
        var rules = """
            # 任务
            你只写照片标签，不写台词，不扮演角色。她会按这个标签生成一张照片。
            """
        rules += """
            # 格式
            只输出一个 <photo> 标签，一行一栏，栏名用英文：
            <photo>
            \(adult ? "rating: questionable    # general | sensitive | questionable | explicit\\n" : "")shot: \(faceToFace ? "other" : "selfie")    # selfie | other
            framing: upper body    # portrait | upper body | cowboy shot | full body
            place: cafe, indoors, afternoon, sunlight
            outfit: white shirt, cardigan
            action: peace sign, smile
            note: 一句中文说明
            </photo>

            place、outfit、action 用 Danbooru 的常见英文 tag，三栏合计不超过 12 个；
            不要写外貌、画风或画师。按对话里此刻的地点、穿着和正在做的事写，
            不要只写表情。\(faceToFace ? "制作人正和她在一起；他要拍她，所以默认 shot: other，除非他要自拍。" : "")
            """
        if adult {
            rules += """
                \n成人模式下，rating 写清内容程度；露骨内容要写进 outfit / action 的 tag
                （例如 nude、topless、sex、riding），光把 rating 写高不会让画面更露骨。
                """
        }
        return rules.replacingOccurrences(of: "她", with: characterName)
    }

    /// The tag out of whatever the model wrote: fenced or not, with or without prose.
    static func photoTagFromAnswer(_ raw: String) throws -> PhotoTag {
        guard let open = raw.range(of: "<photo>"),
              let close = raw.range(of: "</photo>", range: open.upperBound..<raw.endIndex)
        else {
            throw PhotoTagError.malformed("模型没有写出完整的 <photo> 标签")
        }
        let body = String(raw[open.upperBound..<close.lowerBound])
        return try PhotoTag(text: body)
    }
}
