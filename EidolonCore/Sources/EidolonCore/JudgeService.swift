import Foundation

/// Which service judges each turn (ADR-0016): Alibaba Cloud Model Studio's System One, Jev's
/// System One, Cloudflare Workers AI's clef, or the chat model asked again (ADR-0005). The
/// app keeps each service's address and model in its preferences and its key in the
/// Keychain, under an account of its own, so switching services never reads one service's
/// key for another.
public enum JudgeService: String, Sendable, CaseIterable, Codable, Identifiable {
    case bailian
    case jev
    case cloudflare
    case chat

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bailian: "阿里云百炼"
        case .jev: "Jev"
        case .cloudflare: "Cloudflare"
        case .chat: "对话模型（JSON）"
        }
    }

    /// Where this service's key is kept. Every service has an entry of its own; the chat
    /// judge's is the one older installs already had.
    public var keychainAccount: String {
        switch self {
        case .bailian: "judge.bailian.key"
        case .jev: "judge.jev.key"
        case .cloudflare: "judge.cloudflare.key"
        case .chat: "judge.apiKey"
        }
    }

    /// The service a launch should use: the one stored, or — on an install from before the
    /// choice was stored — the chat judge when its fields were filled in, because that is
    /// what the install was using, rather than the newest default.
    public static func atLaunch(stored: String?, chatJudgeFilledIn: Bool) -> JudgeService {
        if let stored, let service = JudgeService(rawValue: stored) { return service }
        return chatJudgeFilledIn ? .chat : .bailian
    }
}
