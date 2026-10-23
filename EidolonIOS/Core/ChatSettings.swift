import EidolonCore
import Foundation

/// The chat and judge model settings: addresses and model names in UserDefaults, keys in
/// the Keychain (ADR-0010). A judge left blank uses the chat model's settings.
struct ChatSettings {
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    var historyTurns: Int = 20
    var extraBody: String = ""

    var judgeBaseURL: String = ""
    var judgeModel: String = ""
    var judgeAPIKey: String = ""
    var judgeExtraBody: String = ""

    var retrievalBaseURL: String = ""
    var embeddingModel: String = ""
    var rerankModel: String = ""
    var retrievalAPIKey: String = ""
    /// How long she waits before saying something first (ADR-0009).
    var reachOutHours: Int = 6
    /// Whether a turn leaves a trace, and how many are kept (ADR-0012).
    var tracingEnabled: Bool = true
    var traceRetention: Int = 200

    private static let baseURLKey = "chat.baseURL"
    private static let modelKey = "chat.model"
    private static let historyKey = "chat.historyTurns"
    private static let extraBodyKey = "chat.extraBody"
    private static let keychainAccount = "chat.apiKey"

    private static let judgeBaseURLKey = "judge.baseURL"
    private static let judgeModelKey = "judge.model"
    private static let judgeExtraBodyKey = "judge.extraBody"
    private static let judgeKeychainAccount = "judge.apiKey"

    private static let retrievalBaseURLKey = "retrieval.baseURL"
    private static let embeddingModelKey = "retrieval.embeddingModel"
    private static let rerankModelKey = "retrieval.rerankModel"
    private static let retrievalKeychainAccount = "retrieval.apiKey"
    private static let reachOutHoursKey = "reachOut.hours"
    private static let tracingEnabledKey = "trace.enabled"
    private static let traceRetentionKey = "trace.retention"

    static func load() -> ChatSettings {
        let defaults = UserDefaults.standard
        return ChatSettings(
            baseURL: defaults.string(forKey: baseURLKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? "",
            apiKey: Keychain.string(account: keychainAccount) ?? "",
            historyTurns: defaults.object(forKey: historyKey) as? Int ?? 20,
            extraBody: defaults.string(forKey: extraBodyKey) ?? "",
            judgeBaseURL: defaults.string(forKey: judgeBaseURLKey) ?? "",
            judgeModel: defaults.string(forKey: judgeModelKey) ?? "",
            judgeAPIKey: Keychain.string(account: judgeKeychainAccount) ?? "",
            judgeExtraBody: defaults.string(forKey: judgeExtraBodyKey) ?? "",
            retrievalBaseURL: defaults.string(forKey: retrievalBaseURLKey) ?? "",
            embeddingModel: defaults.string(forKey: embeddingModelKey) ?? "",
            rerankModel: defaults.string(forKey: rerankModelKey) ?? "",
            retrievalAPIKey: Keychain.string(account: retrievalKeychainAccount) ?? "",
            reachOutHours: defaults.object(forKey: reachOutHoursKey) as? Int ?? 6,
            tracingEnabled: defaults.object(forKey: tracingEnabledKey) as? Bool ?? true,
            traceRetention: defaults.object(forKey: traceRetentionKey) as? Int ?? 200
        )
    }

    func save() throws {
        let defaults = UserDefaults.standard
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.baseURLKey)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelKey)
        defaults.set(historyTurns, forKey: Self.historyKey)
        defaults.set(extraBody.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.extraBodyKey)
        defaults.set(judgeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.judgeBaseURLKey)
        defaults.set(judgeModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.judgeModelKey)
        defaults.set(judgeExtraBody.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.judgeExtraBodyKey)
        try Self.store(apiKey, account: Self.keychainAccount)
        defaults.set(retrievalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.retrievalBaseURLKey)
        defaults.set(embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.embeddingModelKey)
        defaults.set(rerankModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.rerankModelKey)
        try Self.store(judgeAPIKey, account: Self.judgeKeychainAccount)
        try Self.store(retrievalAPIKey, account: Self.retrievalKeychainAccount)
        defaults.set(reachOutHours, forKey: Self.reachOutHoursKey)
        defaults.set(tracingEnabled, forKey: Self.tracingEnabledKey)
        defaults.set(traceRetention, forKey: Self.traceRetentionKey)
    }

    /// The provider config, or nil while something still has to be filled in.
    var config: ChatModelConfig? {
        guard let url = Self.url(baseURL),
              let name = Self.value(model),
              let key = Self.value(apiKey),
              let extra = Self.extra(extraBody)
        else { return nil }
        return ChatModelConfig(
            baseURL: url,
            model: name,
            apiKey: key,
            historyTurns: historyTurns,
            extraBody: extra
        )
    }

    var isConfigured: Bool { config != nil }

    /// The judge's config: its own when filled in, else the chat model's. Nil when neither
    /// is usable, in which case turns go unjudged.
    func judgeConfig(chat: ChatModelConfig?) -> JudgeConfig? {
        if let url = Self.url(judgeBaseURL),
           let name = Self.value(judgeModel),
           let key = Self.value(judgeAPIKey),
           let extra = Self.extra(judgeExtraBody)
        {
            return JudgeConfig(baseURL: url, model: name, apiKey: key, extraBody: extra)
        }
        guard let chat else { return nil }
        return JudgeConfig(
            baseURL: chat.baseURL,
            model: chat.model,
            apiKey: chat.apiKey,
            extraBody: chat.extraBody
        )
    }

    /// The retrieval services: SiliconFlow's Qwen embedding and reranker unless filled in
    /// otherwise. Nil without a key, and then retrieval is off.
    var embeddingConfig: EmbeddingConfig? {
        guard let url = Self.url(retrievalBaseURL) ?? URL(string: "https://api.siliconflow.cn/v1"),
              let key = Self.value(retrievalAPIKey)
        else { return nil }
        let model = Self.value(embeddingModel) ?? "Qwen/Qwen3-Embedding-0.6B"
        return EmbeddingConfig(baseURL: url, model: model, apiKey: key)
    }

    var rerankConfig: RerankConfig? {
        guard let url = Self.url(retrievalBaseURL) ?? URL(string: "https://api.siliconflow.cn/v1"),
              let key = Self.value(retrievalAPIKey)
        else { return nil }
        let model = Self.value(rerankModel) ?? "Qwen/Qwen3-Reranker-0.6B"
        return RerankConfig(baseURL: url, model: model, apiKey: key)
    }

    // MARK: - Helpers

    private static func store(_ key: String, account: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.remove(account: account)
        } else {
            try Keychain.set(trimmed, account: account)
        }
    }

    private static func value(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func url(_ text: String) -> URL? {
        guard let trimmed = value(text), let url = URL(string: trimmed), url.scheme != nil
        else { return nil }
        return url
    }

    /// `nil` for blank, otherwise the parsed object; a JSON text that cannot be parsed
    /// makes the whole configuration unusable rather than silently ignored.
    private static func extra(_ text: String) -> [String: JSONValue]?? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .some(nil) }
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return nil }
        return .some(decoded)
    }
}
