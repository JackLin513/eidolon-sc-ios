import EidolonCore

/// One row of a conversation as shown: a turn, or something that happened instead of one.
enum ChatLine: Identifiable {
    case message(ChatMessageRecord)
    case event(ConversationEventRecord)

    var id: String {
        switch self {
        case let .message(message): "message-\(message.id)"
        case let .event(event): "event-\(event.id)"
        }
    }

    var createdAt: String {
        switch self {
        case let .message(message): message.createdAt
        case let .event(event): event.createdAt
        }
    }
}
