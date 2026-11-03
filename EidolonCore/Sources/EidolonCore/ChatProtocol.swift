import Foundation

/// The three interfaces a chat model can speak (upstream `LLMProtocol`). The turn engine
/// sees only `ChatProvider`; which adapter answers is the settings' choice.
public enum ChatProtocol: String, Sendable, Codable, CaseIterable, Identifiable {
    case chatCompletions = "chat-completions"
    case responses
    case anthropic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        case .anthropic: "Anthropic Messages"
        }
    }

    /// What the settings page shows beside the picker: the path the protocol calls.
    public var path: String {
        switch self {
        case .chatCompletions: "/chat/completions"
        case .responses: "/responses"
        case .anthropic: "/messages"
        }
    }

    /// Anthropic has no `minimal` (upstream refuses it for that protocol).
    public func supports(_ effort: ReasoningEffort) -> Bool {
        !(self == .anthropic && effort == .minimal)
    }
}

/// How hard the model is asked to think, sent as the protocol's own parameter
/// (upstream `ReasoningEffort`).
public enum ReasoningEffort: String, Sendable, Codable, CaseIterable, Identifiable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "none（关闭）"
        case .minimal: "minimal（最少）"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "xhigh"
        case .max: "max"
        }
    }

    public static func parse(_ text: String) -> ReasoningEffort? {
        ReasoningEffort(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// The extra request body (`CHAT_LLM_EXTRA_BODY`): a JSON object merged into the request
/// last, so it can override what the protocol generated — except the fields the app itself
/// writes, which would break the request.
public enum ChatRequestExtras {
    public static let reservedKeys: Set<String> = [
        "model", "stream", "stream_options", "messages", "input", "instructions",
        "system", "tools", "tool_choice",
    ]

    public enum ValidationError: LocalizedError, Equatable {
        case notAnObject
        case reserved(String)

        public var errorDescription: String? {
            switch self {
            case .notAnObject:
                return "额外参数需要是一个 JSON 对象"
            case let .reserved(key):
                return "额外参数不能包含「\(key)」，它由 App 生成"
            }
        }
    }

    /// Blank is no extras; unreadable JSON and anything but an object are errors.
    public static func decode(_ text: String) throws -> [String: JSONValue]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let data = trimmed.data(using: .utf8) else {
            throw ValidationError.notAnObject
        }
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(value) = object
        else {
            throw ValidationError.notAnObject
        }
        try validate(value)
        return value
    }

    public static func validate(_ object: [String: JSONValue]) throws {
        if let key = object.keys.sorted().first(where: { reservedKeys.contains($0) }) {
            throw ValidationError.reserved(key)
        }
    }

    /// The body with `extra` merged in deeply, last. Objects merge key by key; anything
    /// else replaces what was there.
    public static func merged(
        _ extra: [String: JSONValue]?,
        into body: [String: Any]
    ) -> [String: Any] {
        guard let extra else { return body }
        var merged = body
        for (key, value) in extra {
            merged[key] = mergedValue(merged[key], with: value)
        }
        return merged
    }

    private static func mergedValue(_ existing: Any?, with value: JSONValue) -> Any {
        if case let .object(fields) = value, let current = existing as? [String: Any] {
            var merged = current
            for (key, field) in fields {
                merged[key] = mergedValue(merged[key], with: field)
            }
            return merged
        }
        return value.jsonObject
    }
}

/// A background model as the producer wrote it, before the empty fields fall back to the
/// chat model (upstream `BACKGROUND_LLM_*`). The reply cap, the reasoning effort and the
/// extra body do not fall back: each model sets its own.
public struct BackgroundChatConfig: Sendable, Hashable {
    public var apiProtocol: ChatProtocol?
    public var baseURL: URL?
    public var model: String?
    public var apiKey: String?
    public var maxTokens: Int?
    public var reasoningEffort: ReasoningEffort?
    public var extraBody: [String: JSONValue]?

    public init(
        apiProtocol: ChatProtocol? = nil,
        baseURL: URL? = nil,
        model: String? = nil,
        apiKey: String? = nil,
        maxTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        extraBody: [String: JSONValue]? = nil
    ) {
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
        self.extraBody = extraBody
    }

    /// Whether any field is filled in. With everything blank there is no background model
    /// and the chat model writes memories and titles, as before.
    public var isEnabled: Bool {
        apiProtocol != nil || baseURL != nil || model != nil || apiKey != nil
            || maxTokens != nil || reasoningEffort != nil || extraBody != nil
    }

    /// The config the background jobs use: each empty field from `chat`, the three
    /// per-model fields from this one. Nil while a required field is missing either way.
    public func config(inheriting chat: ChatModelConfig) -> ChatModelConfig? {
        guard isEnabled else { return nil }
        let apiProtocol = self.apiProtocol ?? chat.apiProtocol
        let baseURL = self.baseURL ?? chat.baseURL
        let model = self.model ?? chat.model
        let apiKey = self.apiKey ?? chat.apiKey
        guard !model.isEmpty, !apiKey.isEmpty else { return nil }
        return ChatModelConfig(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            historyTurns: chat.historyTurns,
            maxTokens: maxTokens,
            apiProtocol: apiProtocol,
            reasoningEffort: reasoningEffort,
            extraBody: extraBody
        )
    }
}
