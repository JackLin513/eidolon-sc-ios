import Foundation

struct Account: Decodable, Identifiable {
    let id: String
    let name: String
}

struct Character: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let intro: String
    let color: String
    let avatarUrl: String?
    let nameZh: String?
    let nameKana: String?
    let nameRomaji: String?
    let unit: String?

    /// The Chinese/kana/romaji line under her name in the list, whichever there is first.
    var subtitle: String {
        [nameZh, nameKana, nameRomaji].compactMap { $0 }.first ?? unit ?? ""
    }
}

struct Conversation: Decodable {
    let id: String
    let characterId: String
    let createdAt: String
}

struct LatestConversation: Decodable, Identifiable {
    let characterId: String
    let conversationId: String
    let createdAt: String
    let lastMessage: LastMessage?
    let unseenReachOut: Bool

    var id: String { conversationId }
}

/// The last thing in a conversation, as the list shows it.
struct LastMessage: Decodable {
    let role: String?
    let text: String?
    let ja: String?
    let zh: String?
    let createdAt: String?
    let photo: Bool?
    let reachOut: Bool?
    let type: String?
    let kind: String?

    var preview: String? {
        if let zh, !zh.isEmpty { return zh }
        if let ja, !ja.isEmpty { return ja }
        if let text, !text.isEmpty { return text }
        if type == "event" { return kind == "ended" ? "这段对话结束了" : "对话事件" }
        return nil
    }
}

struct Segment: Decodable, Hashable {
    let ja: String
    let zh: String
}

struct Photo: Decodable, Hashable {
    let id: String
    let status: String
    let reason: String?
}

/// One entry in a conversation's record: a message, a conversation event, or a reach-out.
/// Messages carry no `type`; the other two say which they are.
struct RecordItem: Decodable, Identifiable {
    let id: Int
    let type: String?
    let role: String?
    let text: String?
    let ja: String?
    let zh: String?
    let segments: [Segment]?
    let createdAt: String
    let kind: String?
    let photo: Photo?

    var uid: String { "\(type ?? "message")-\(id)" }
    var isEvent: Bool { type == "event" }
    var isReachOut: Bool { type == "reach_out" }
    var isCharacter: Bool { isReachOut || role == "character" }

    var japanese: String {
        if let ja, !ja.isEmpty { return ja }
        return segments?.map(\.ja).joined() ?? ""
    }

    var chinese: String {
        if let zh, !zh.isEmpty { return zh }
        return segments?.map(\.zh).joined() ?? ""
    }

    var eventDescription: String {
        switch kind {
        case "gift": return "你送了她一件礼物"
        case "hung_up": return "她挂断了电话"
        case "ended": return "这段对话结束了"
        default: return "对话事件"
        }
    }
}

/// One server-sent event from a text turn.
struct TurnEvent: Decodable {
    let type: String
    let text: String?
    let segment: Int?
    let lang: String?
    let detail: String?
    let retryAt: String?
}

struct ChatTarget: Hashable {
    let character: Character
    let conversationID: String
}
