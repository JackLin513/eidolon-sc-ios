import EidolonCore
import Foundation

/// The chat and judge model settings: addresses and model names in UserDefaults, keys in
/// the Keychain (ADR-0010). A chat judge left blank uses the chat model's settings.
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

    /// Calls: the recognizer's key and model, and the voice model her speech is made on.
    var sonioxAPIKey: String = ""
    var sonioxModel: String = "stt-rt-v5"
    var fishAPIKey: String = ""
    var fishModel: String = "s2.1-pro-free"

    /// How long one call may last and how many of her turns it may take; 0 is no limit
    /// on that dimension, as upstream's environment reads it (ADR-0007).
    var callMinutes: Int = 10
    var callTurns: Int = 40

    /// Who judges each turn (ADR-0016): Alibaba Cloud Model Studio's System One by
    /// default, Jev or Cloudflare, or the chat model asked again, as before.
    var judgeService: JudgeService = .bailian
    var bailianWorkspace: String = ""
    var bailianRegion: BailianRegion = .beijing
    var bailianModel: String = "decision-model-preview"
    var bailianAPIKey: String = ""
    var jevBaseURL: String = JevJudgeConfig.defaultBaseURL
    var jevModel: String = JevJudgeConfig.defaultModel
    var jevAPIKey: String = ""
    var cloudflareAccountID: String = ""
    var cloudflareModel: String = CloudflareJudgeConfig.defaultModel
    var cloudflareAPIKey: String = ""

    private static let baseURLKey = "chat.baseURL"
    private static let modelKey = "chat.model"
    private static let historyKey = "chat.historyTurns"
    private static let extraBodyKey = "chat.extraBody"
    private static let keychainAccount = "chat.apiKey"

    private static let judgeBaseURLKey = "judge.baseURL"
    private static let judgeModelKey = "judge.model"
    private static let judgeExtraBodyKey = "judge.extraBody"

    private static let retrievalBaseURLKey = "retrieval.baseURL"
    private static let embeddingModelKey = "retrieval.embeddingModel"
    private static let rerankModelKey = "retrieval.rerankModel"
    private static let retrievalKeychainAccount = "retrieval.apiKey"
    private static let reachOutHoursKey = "reachOut.hours"
    private static let tracingEnabledKey = "trace.enabled"
    private static let traceRetentionKey = "trace.retention"
    private static let sonioxModelKey = "call.sonioxModel"
    private static let sonioxKeychainAccount = "call.sonioxKey"
    private static let fishModelKey = "call.fishModel"
    private static let fishKeychainAccount = "call.fishKey"
    private static let callMinutesKey = "call.minutes"
    private static let callTurnsKey = "call.turns"
    private static let judgeServiceKey = "judge.service"
    private static let bailianWorkspaceKey = "judge.bailian.workspace"
    private static let bailianRegionKey = "judge.bailian.region"
    private static let bailianModelKey = "judge.bailian.model"
    private static let jevBaseURLKey = "judge.jev.baseURL"
    private static let jevModelKey = "judge.jev.model"
    private static let cloudflareAccountKey = "judge.cloudflare.account"
    private static let cloudflareModelKey = "judge.cloudflare.model"

    static func load() -> ChatSettings {
        let defaults = UserDefaults.standard
        let judgeBaseURL = defaults.string(forKey: judgeBaseURLKey) ?? ""
        let judgeModel = defaults.string(forKey: judgeModelKey) ?? ""
        let judgeAPIKey = Keychain.string(account: JudgeService.chat.keychainAccount) ?? ""
        return ChatSettings(
            baseURL: defaults.string(forKey: baseURLKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? "",
            apiKey: Keychain.string(account: keychainAccount) ?? "",
            historyTurns: defaults.object(forKey: historyKey) as? Int ?? 20,
            extraBody: defaults.string(forKey: extraBodyKey) ?? "",
            judgeBaseURL: judgeBaseURL,
            judgeModel: judgeModel,
            judgeAPIKey: judgeAPIKey,
            judgeExtraBody: defaults.string(forKey: judgeExtraBodyKey) ?? "",
            retrievalBaseURL: defaults.string(forKey: retrievalBaseURLKey) ?? "",
            embeddingModel: defaults.string(forKey: embeddingModelKey) ?? "",
            rerankModel: defaults.string(forKey: rerankModelKey) ?? "",
            retrievalAPIKey: Keychain.string(account: retrievalKeychainAccount) ?? "",
            reachOutHours: defaults.object(forKey: reachOutHoursKey) as? Int ?? 6,
            tracingEnabled: defaults.object(forKey: tracingEnabledKey) as? Bool ?? true,
            traceRetention: defaults.object(forKey: traceRetentionKey) as? Int ?? 200,
            sonioxAPIKey: Keychain.string(account: sonioxKeychainAccount) ?? "",
            sonioxModel: defaults.string(forKey: sonioxModelKey) ?? "stt-rt-v5",
            fishAPIKey: Keychain.string(account: fishKeychainAccount) ?? "",
            fishModel: defaults.string(forKey: fishModelKey) ?? "s2.1-pro-free",
            callMinutes: defaults.object(forKey: callMinutesKey) as? Int ?? 10,
            callTurns: defaults.object(forKey: callTurnsKey) as? Int ?? 40,
            judgeService: JudgeService.atLaunch(
                stored: defaults.string(forKey: judgeServiceKey),
                chatJudgeFilledIn: [judgeBaseURL, judgeModel, judgeAPIKey].contains {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            ),
            bailianWorkspace: defaults.string(forKey: bailianWorkspaceKey) ?? "",
            bailianRegion: BailianRegion(
                rawValue: defaults.string(forKey: bailianRegionKey) ?? ""
            ) ?? .beijing,
            bailianModel: defaults.string(forKey: bailianModelKey) ?? "decision-model-preview",
            bailianAPIKey: Keychain.string(account: JudgeService.bailian.keychainAccount) ?? "",
            jevBaseURL: defaults.string(forKey: jevBaseURLKey) ?? JevJudgeConfig.defaultBaseURL,
            jevModel: defaults.string(forKey: jevModelKey) ?? JevJudgeConfig.defaultModel,
            jevAPIKey: Keychain.string(account: JudgeService.jev.keychainAccount) ?? "",
            cloudflareAccountID: defaults.string(forKey: cloudflareAccountKey) ?? "",
            cloudflareModel: defaults.string(forKey: cloudflareModelKey)
                ?? CloudflareJudgeConfig.defaultModel,
            cloudflareAPIKey: Keychain.string(account: JudgeService.cloudflare.keychainAccount) ?? ""
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
        try Self.store(judgeAPIKey, account: JudgeService.chat.keychainAccount)
        try Self.store(retrievalAPIKey, account: Self.retrievalKeychainAccount)
        defaults.set(reachOutHours, forKey: Self.reachOutHoursKey)
        defaults.set(tracingEnabled, forKey: Self.tracingEnabledKey)
        defaults.set(traceRetention, forKey: Self.traceRetentionKey)
        defaults.set(sonioxModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.sonioxModelKey)
        defaults.set(fishModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.fishModelKey)
        defaults.set(max(0, callMinutes), forKey: Self.callMinutesKey)
        defaults.set(max(0, callTurns), forKey: Self.callTurnsKey)
        try Self.store(sonioxAPIKey, account: Self.sonioxKeychainAccount)
        try Self.store(fishAPIKey, account: Self.fishKeychainAccount)
        defaults.set(judgeService.rawValue, forKey: Self.judgeServiceKey)
        defaults.set(
            bailianWorkspace.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.bailianWorkspaceKey
        )
        defaults.set(bailianRegion.rawValue, forKey: Self.bailianRegionKey)
        defaults.set(
            bailianModel.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.bailianModelKey
        )
        try Self.store(bailianAPIKey, account: JudgeService.bailian.keychainAccount)
        defaults.set(
            jevBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.jevBaseURLKey
        )
        defaults.set(jevModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.jevModelKey)
        try Self.store(jevAPIKey, account: JudgeService.jev.keychainAccount)
        defaults.set(
            cloudflareAccountID.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.cloudflareAccountKey
        )
        defaults.set(
            cloudflareModel.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.cloudflareModelKey
        )
        try Self.store(cloudflareAPIKey, account: JudgeService.cloudflare.keychainAccount)
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

    /// The Bailian judge, or nil while the workspace, the model or the key is still
    /// blank. Only asked when the judge service is Bailian.
    var bailianJudgeConfig: SystemOneConfig? {
        BailianJudgeConfig(
            workspaceID: bailianWorkspace,
            region: bailianRegion,
            model: bailianModel,
            apiKey: bailianAPIKey
        ).systemOne
    }

    /// The Jev judge, or nil while the address, the model or the key is still blank.
    var jevJudgeConfig: SystemOneConfig? {
        JevJudgeConfig(
            baseURL: jevBaseURL,
            model: jevModel,
            apiKey: jevAPIKey
        ).systemOne
    }

    /// The Cloudflare judge, or nil while the account, the model or the key is still blank.
    var cloudflareJudgeConfig: SystemOneConfig? {
        CloudflareJudgeConfig(
            accountID: cloudflareAccountID,
            model: cloudflareModel,
            apiKey: cloudflareAPIKey
        ).systemOne
    }

    /// What the next call gets: the limits as the settings write them, 0 meaning none
    /// (ADR-0007). A call keeps what it started with; changing these affects the next one.
    var callLimits: CallLimits {
        CallLimits(minutes: max(0, callMinutes), turns: max(0, callTurns))
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
