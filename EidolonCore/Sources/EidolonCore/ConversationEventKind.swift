import Foundation

/// Something that happened in a conversation besides a turn (GLOSSARY.md「对话事件」),
/// as the library keeps it in `conversation_events.kind`. `rawValue` is exactly what is
/// written, so the record, the prompt and the screens all read the same kind. A kind this
/// build does not know — written by a newer build, or left by an old one — is kept as it
/// is and shown with the generic words rather than breaking the conversation.
public enum ConversationEventKind: Sendable, Hashable {
    /// She hung up the call herself (upstream records this one; it is narrated to her).
    case hungUp
    /// She ended the conversation (only read by a turn it will reject, upstream `ended`).
    case ended
    /// A kind this build does not know: the words are generic and she is not told of it.
    case other(String)

    public init(stored kind: String) {
        switch kind {
        case "hung_up": self = .hungUp
        case "ended": self = .ended
        default: self = .other(kind)
        }
    }

    /// The string the library keeps, and the one a new event is recorded with.
    public var rawValue: String {
        switch self {
        case .hungUp: "hung_up"
        case .ended: "ended"
        case let .other(kind): kind
        }
    }

    /// What the chat and the conversation list show for it.
    public var displayText: String {
        switch self {
        case .hungUp: "她挂断了电话"
        case .ended: "她结束了对话"
        case .other: "通话结束"
        }
    }

    /// What she is told of it as narration, before the next thing the producer says
    /// (upstream `engine._narration`); nil for what she is not told of.
    public var narration: String? {
        switch self {
        case .hungUp: "（你挂断了制作人的电话。）"
        case .ended: "（你结束了和制作人的对话。）"
        case .other: nil
        }
    }

    /// The SF Symbol the chat shows beside it.
    public var icon: String {
        switch self {
        case .hungUp: "phone.down"
        case .ended: "moon.zzz"
        case .other: "phone.down"
        }
    }
}
