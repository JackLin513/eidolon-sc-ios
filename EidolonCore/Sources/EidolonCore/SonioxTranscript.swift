import Foundation

/// What a Soniox stream says, as it comes: words still being said, the end of what was
/// said, and the end of the stream.
public enum SpeechUpdate: Sendable, Hashable {
    case partial(String)
    case final(String)
    case ended
}

/// How a Soniox real-time stream is opened. The producer may speak Chinese or Japanese:
/// upstream hears both (`language_hints=[ZH, JA]`), and hints only bias the recognizer.
/// `terms` are the names it should write as the story writes them (upstream sends its hot
/// words as the context's terms).
public struct SonioxConfiguration: Sendable {
    public var apiKey: String
    public var model: String
    public var languageHints: [String]
    public var terms: [String]

    public init(
        apiKey: String,
        model: String,
        languageHints: [String] = ["zh", "ja"],
        terms: [String] = []
    ) {
        self.apiKey = apiKey
        self.model = model
        self.languageHints = languageHints
        self.terms = terms
    }

    /// The first message of the stream, as JSON.
    public func message() throws -> String {
        var object: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "num_channels": 1,
            "sample_rate": 16_000,
            "language_hints": languageHints,
            "enable_endpoint_detection": true,
        ]
        if !terms.isEmpty {
            object["context"] = ["terms": terms]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

/// Reads the JSON messages of Soniox's real-time transcription. Tokens that are final are
/// kept until the end token says the producer stopped speaking; the words still open are
/// shown along with them, as Soniox rewrites them.
public struct SonioxTranscript: Sendable {
    /// The tokens Soniox marks the end of a turn with.
    static let endTokens: Set<String> = ["<end>", "<fin>"]
    /// The token Soniox auto-finalizes with, alone in a message of its own.
    static let finalizedToken = "<fin>"

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
        // Soniox's auto-finalize may send a message holding nothing but `<fin>`: it is not
        // the producer stopping, so what was said stays open (upstream's pipecat service
        // skips the finalized token, "prevent auto-finalize cycling").
        let autoFinalized = tokens.count == 1 && tokens[0].text == Self.finalizedToken
        var open = ""
        for token in tokens where !autoFinalized {
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
        if !autoFinalized, !shown.isEmpty, !tokens.isEmpty {
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
