import Foundation

/// What a Soniox stream says, as it comes: words still being said, the end of what was
/// said, and the end of the stream.
public enum SpeechUpdate: Sendable, Hashable {
    case partial(String)
    case final(String)
    case ended
}

/// Reads the JSON messages of Soniox's real-time transcription. Tokens that are final are
/// kept until the end token says the producer stopped speaking; the words still open are
/// shown along with them, as Soniox rewrites them.
public struct SonioxTranscript: Sendable {
    /// The tokens Soniox marks the end of a turn with.
    static let endTokens: Set<String> = ["<end>", "<fin>"]

    private var finals: [String] = []

    public init() {}

    public mutating func feed(_ data: Data) throws -> [SpeechUpdate] {
        struct Message: Decodable {
            struct Token: Decodable {
                var text: String
                var isFinal: Bool?
                enum CodingKeys: String, CodingKey {
                    case text
                    case isFinal = "is_final"
                }
            }
            var tokens: [Token]?
            var errorCode: String?
            var errorMessage: String?
            var finished: Bool?
            enum CodingKeys: String, CodingKey {
                case tokens
                case errorCode = "error_code"
                case errorMessage = "error_message"
                case finished
            }
        }

        let message = try JSONDecoder().decode(Message.self, from: data)
        if let code = message.errorCode, !code.isEmpty {
            throw SonioxError.service(code, message.errorMessage ?? "")
        }
        if let text = message.errorMessage, !text.isEmpty {
            throw SonioxError.service("", text)
        }

        var updates: [SpeechUpdate] = []
        let tokens = message.tokens ?? []
        var open = ""
        for token in tokens {
            if Self.endTokens.contains(token.text) {
                if token.isFinal == true {
                    let said = finals.joined()
                    if !said.isEmpty { updates.append(.final(said)) }
                    finals.removeAll()
                }
                continue
            }
            if token.isFinal == true {
                finals.append(token.text)
            } else {
                open += token.text
            }
        }
        let shown = finals.joined() + open
        if !shown.isEmpty, !tokens.isEmpty {
            updates.append(.partial(shown))
        }
        if message.finished == true {
            let said = finals.joined() + open
            if !said.isEmpty { updates.append(.final(said)) }
            finals.removeAll()
            updates.append(.ended)
        }
        return updates
    }
}

public enum SonioxError: LocalizedError, Equatable {
    case service(String, String)

    public var errorDescription: String? {
        switch self {
        case let .service(code, message):
            let head = code.isEmpty ? "" : "\(code) "
            return "识别服务出错：\(head)\(message)"
        }
    }
}
