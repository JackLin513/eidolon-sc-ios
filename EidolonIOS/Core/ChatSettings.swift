import EidolonCore
import Foundation

/// The chat and judge model settings: addresses and model names in UserDefaults, keys in
/// the Keychain (ADR-0010). A chat judge left blank uses the chat model's settings.
struct ChatSettings: Equatable {
    // MARK: Chat model

    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    var historyTurns: Int = 20
    /// 文字氛围模式: text turns may use longer lines and scene blocks; calls never do.
    var atmosphericText: Bool = true
    /// Adult mode: consensual intimacy is not out of line, but only for characters whose
    /// content age is 18 or older (spec #61).
    var adultMode: Bool = false
    /// The interface the address speaks (spec #80): chat-completions, Responses or
    /// Anthropic Messages.
    var apiProtocol: ChatProtocol = .chatCompletions
    /// The reply cap; nil means the protocol's own default (Anthropic 16384, the other
    /// two no cap).
    var maxTokens: Int?
    /// How hard the model thinks on typed turns.
    var textReasoningEffort: ReasoningEffort?
    /// How hard the model thinks in a call; separate so a call can answer sooner.
    var callReasoningEffort: ReasoningEffort?
    var extraBody: String = ""

    // MARK: Background model (memories and titles)

    /// Empty fields fall back to the chat model's; the reply cap, the effort and the extra
    /// body are the background model's own, as upstream has them.
    var backgroundProtocol: ChatProtocol?
    var backgroundBaseURL: String = ""
    var backgroundModel: String = ""
    var backgroundAPIKey: String = ""
    var backgroundMaxTokens: Int?
    var backgroundTextReasoningEffort: ReasoningEffort?
    var backgroundExtraBody: String = ""

    // MARK: Judge

    var judgeBaseURL: String = ""
    var judgeModel: String = ""
    var judgeAPIKey: String = ""
    var judgeExtraBody: String = ""

    // MARK: Retrieval

    var retrievalBaseURL: String = ""
    /// Which embedding service to use before a content bundle names one.
    var embeddingProvider: EmbeddingService = .siliconflow
    var embeddingModel: String = ""
    var embeddingDimensions: Int?
    var rerankModel: String = ""
    var retrievalAPIKey: String = ""
    /// Gemini's key and address, kept apart from SiliconFlow's: a Gemini bundle still
    /// reranks on SiliconFlow.
    var geminiAPIKey: String = ""
    var geminiBaseURL: String = ""
    /// How long she waits before saying something first, when she does not go by her tier
    /// (ADR-0009).
    var reachOutHours: Int = 6
    /// Whether her waiting time is drawn from her affinity tier's range rather than fixed.
    var reachOutByTier: Bool = true
    /// Whether a turn leaves a trace, and how many are kept (ADR-0012).
    var tracingEnabled: Bool = true
    var traceRetention: Int = 200

    // MARK: Calls

    /// Calls: which recognizer hears the producer, its key and model, and the voice model
    /// her speech is made on.
    var speechToText: SpeechToTextService = .soniox
    var sonioxAPIKey: String = ""
    var sonioxModel: String = "stt-rt-v5"
    var dashscopeAPIKey: String = ""
    var bailianSTTModel: String = BailianSTTConfiguration.defaultModel
    var fishAPIKey: String = ""
    var fishModel: String = "s2.1-pro-free"

    /// How long one call may last and how many of her turns it may take; 0 is no limit
    /// on that dimension, as upstream's environment reads it (ADR-0007).
    var callMinutes: Int = 10
    var callTurns: Int = 40
    /// Whether her voice is put through a telephone line on the next call.
    var phoneTexture: Bool = false

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
    /// How sure the judge must be of a segment's emotion before she shows it; nil uses the
    /// judge model family's own threshold (spec「情绪判断」).
    var emotionMinProbability: Double?
    /// How long a segment may take to be judged before it goes unjudged, in seconds.
    var emotionTimeout: Double = 1.5

    // MARK: Keys

    private static let baseURLKey = "chat.baseURL"
    private static let modelKey = "chat.model"
    private static let historyKey = "chat.historyTurns"
    private static let atmosphericTextKey = "chat.atmosphericText"
    private static let adultModeKey = "chat.adultMode"
    private static let protocolKey = "chat.protocol"
    private static let maxTokensKey = "chat.maxTokens"
    private static let textEffortKey = "chat.reasoningEffort"
    private static let callEffortKey = "chat.callReasoningEffort"
    private static let extraBodyKey = "chat.extraBody"
    private static let keychainAccount = "chat.apiKey"

    private static let backgroundProtocolKey = "background.protocol"
    private static let backgroundBaseURLKey = "background.baseURL"
    private static let backgroundModelKey = "background.model"
    private static let backgroundMaxTokensKey = "background.maxTokens"
    private static let backgroundEffortKey = "background.reasoningEffort"
    private static let backgroundExtraBodyKey = "background.extraBody"
    private static let backgroundKeychainAccount = "background.apiKey"

    private static let judgeBaseURLKey = "judge.baseURL"
    private static let judgeModelKey = "judge.model"
    private static let judgeExtraBodyKey = "judge.extraBody"

    private static let retrievalBaseURLKey = "retrieval.baseURL"
    private static let embeddingProviderKey = "retrieval.provider"
    private static let embeddingModelKey = "retrieval.embeddingModel"
    private static let embeddingDimensionsKey = "retrieval.embeddingDimensions"
    private static let rerankModelKey = "retrieval.rerankModel"
    private static let retrievalKeychainAccount = "retrieval.apiKey"
    private static let geminiKeychainAccount = "retrieval.geminiKey"
    private static let geminiBaseURLKey = "retrieval.geminiBaseURL"
    private static let reachOutHoursKey = "reachOut.hours"
    private static let reachOutByTierKey = "reachOut.byTier"
    private static let tracingEnabledKey = "trace.enabled"
    private static let traceRetentionKey = "trace.retention"
    private static let speechToTextKey = "call.sttProvider"
    private static let sonioxModelKey = "call.sonioxModel"
    private static let sonioxKeychainAccount = "call.sonioxKey"
    private static let dashscopeKeychainAccount = "call.dashscopeKey"
    private static let bailianSTTModelKey = "call.bailianSTTModel"
    private static let fishModelKey = "call.fishModel"
    private static let fishKeychainAccount = "call.fishKey"
    private static let callMinutesKey = "call.minutes"
    private static let callTurnsKey = "call.turns"
    private static let phoneTextureKey = "call.phoneTexture"
    private static let judgeServiceKey = "judge.service"
    private static let bailianWorkspaceKey = "judge.bailian.workspace"
    private static let bailianRegionKey = "judge.bailian.region"
    private static let bailianModelKey = "judge.bailian.model"
    private static let jevBaseURLKey = "judge.jev.baseURL"
    private static let jevModelKey = "judge.jev.model"
    private static let cloudflareAccountKey = "judge.cloudflare.account"
    private static let cloudflareModelKey = "judge.cloudflare.model"
    private static let emotionMinProbabilityKey = "judge.emotion.minProbability"
    private static let emotionTimeoutKey = "judge.emotion.timeout"

    static func load() -> ChatSettings {
        let defaults = UserDefaults.standard
        let judgeBaseURL = defaults.string(forKey: judgeBaseURLKey) ?? ""
        let judgeModel = defaults.string(forKey: judgeModelKey) ?? ""
        let judgeAPIKey = Keychain.string(account: JudgeService.chat.keychainAccount) ?? ""
        var settings = ChatSettings(
            baseURL: defaults.string(forKey: baseURLKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? "",
            apiKey: Keychain.string(account: keychainAccount) ?? "",
            historyTurns: defaults.object(forKey: historyKey) as? Int ?? 20,
            atmosphericText: defaults.object(forKey: atmosphericTextKey) as? Bool ?? true,
            adultMode: defaults.object(forKey: adultModeKey) as? Bool ?? false,
            apiProtocol: ChatProtocol(rawValue: defaults.string(forKey: protocolKey) ?? "")
                ?? .chatCompletions,
            maxTokens: defaults.object(forKey: maxTokensKey) as? Int,
            textReasoningEffort: ReasoningEffort.parse(
                defaults.string(forKey: textEffortKey) ?? ""
            ),
            callReasoningEffort: ReasoningEffort.parse(
                defaults.string(forKey: callEffortKey) ?? ""
            ),
            extraBody: defaults.string(forKey: extraBodyKey) ?? "",
            backgroundProtocol: ChatProtocol(
                rawValue: defaults.string(forKey: backgroundProtocolKey) ?? ""
            ),
            backgroundBaseURL: defaults.string(forKey: backgroundBaseURLKey) ?? "",
            backgroundModel: defaults.string(forKey: backgroundModelKey) ?? "",
            backgroundAPIKey: Keychain.string(account: backgroundKeychainAccount) ?? "",
            backgroundMaxTokens: defaults.object(forKey: backgroundMaxTokensKey) as? Int,
            backgroundTextReasoningEffort: ReasoningEffort.parse(
                defaults.string(forKey: backgroundEffortKey) ?? ""
            ),
            backgroundExtraBody: defaults.string(forKey: backgroundExtraBodyKey) ?? "",
            judgeBaseURL: judgeBaseURL,
            judgeModel: judgeModel,
            judgeAPIKey: judgeAPIKey,
            judgeExtraBody: defaults.string(forKey: judgeExtraBodyKey) ?? "",
            retrievalBaseURL: defaults.string(forKey: retrievalBaseURLKey) ?? "",
            embeddingProvider: EmbeddingService(
                rawValue: defaults.string(forKey: embeddingProviderKey) ?? ""
            ) ?? .siliconflow,
            embeddingModel: defaults.string(forKey: embeddingModelKey) ?? "",
            embeddingDimensions: defaults.object(forKey: embeddingDimensionsKey) as? Int,
            rerankModel: defaults.string(forKey: rerankModelKey) ?? "",
            retrievalAPIKey: Keychain.string(account: retrievalKeychainAccount) ?? "",
            geminiAPIKey: Keychain.string(account: geminiKeychainAccount) ?? "",
            geminiBaseURL: defaults.string(forKey: geminiBaseURLKey) ?? "",
            reachOutHours: defaults.object(forKey: reachOutHoursKey) as? Int ?? 6,
            reachOutByTier: defaults.object(forKey: reachOutByTierKey) as? Bool ?? true,
            tracingEnabled: defaults.object(forKey: tracingEnabledKey) as? Bool ?? true,
            traceRetention: defaults.object(forKey: traceRetentionKey) as? Int ?? 200,
            speechToText: SpeechToTextService(
                rawValue: defaults.string(forKey: speechToTextKey) ?? ""
            ) ?? .soniox,
            sonioxAPIKey: Keychain.string(account: sonioxKeychainAccount) ?? "",
            sonioxModel: defaults.string(forKey: sonioxModelKey) ?? "stt-rt-v5",
            dashscopeAPIKey: Keychain.string(account: dashscopeKeychainAccount) ?? "",
            bailianSTTModel: defaults.string(forKey: bailianSTTModelKey)
                ?? BailianSTTConfiguration.defaultModel,
            fishAPIKey: Keychain.string(account: fishKeychainAccount) ?? "",
            fishModel: defaults.string(forKey: fishModelKey) ?? "s2.1-pro-free",
            callMinutes: defaults.object(forKey: callMinutesKey) as? Int ?? 10,
            callTurns: defaults.object(forKey: callTurnsKey) as? Int ?? 40,
            phoneTexture: defaults.object(forKey: phoneTextureKey) as? Bool ?? false,
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
            cloudflareAPIKey: Keychain.string(account: JudgeService.cloudflare.keychainAccount) ?? "",
            emotionMinProbability: defaults.object(forKey: emotionMinProbabilityKey) as? Double,
            emotionTimeout: Self.reasonableTimeout(
                defaults.object(forKey: emotionTimeoutKey) as? Double ?? 1.5
            )
        )
        // A build before the routing fix could have saved Anthropic on DeepSeek's root
        // address; reading it back moves it, so chat works without opening settings.
        settings.baseURL = APIServiceRouting.baseURLForImportedSettings(
            settings.baseURL,
            protocol: settings.apiProtocol
        )
        return settings
    }

    func save() throws {
        let defaults = UserDefaults.standard
        defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.baseURLKey)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelKey)
        defaults.set(historyTurns, forKey: Self.historyKey)
        defaults.set(atmosphericText, forKey: Self.atmosphericTextKey)
        defaults.set(adultMode, forKey: Self.adultModeKey)
        defaults.set(apiProtocol.rawValue, forKey: Self.protocolKey)
        if let maxTokens {
            defaults.set(maxTokens, forKey: Self.maxTokensKey)
        } else {
            defaults.removeObject(forKey: Self.maxTokensKey)
        }
        if let textReasoningEffort {
            defaults.set(textReasoningEffort.rawValue, forKey: Self.textEffortKey)
        } else {
            defaults.removeObject(forKey: Self.textEffortKey)
        }
        if let callReasoningEffort {
            defaults.set(callReasoningEffort.rawValue, forKey: Self.callEffortKey)
        } else {
            defaults.removeObject(forKey: Self.callEffortKey)
        }
        defaults.set(extraBody.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.extraBodyKey)
        if let backgroundProtocol {
            defaults.set(backgroundProtocol.rawValue, forKey: Self.backgroundProtocolKey)
        } else {
            defaults.removeObject(forKey: Self.backgroundProtocolKey)
        }
        defaults.set(
            backgroundBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.backgroundBaseURLKey
        )
        defaults.set(backgroundModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.backgroundModelKey)
        if let backgroundMaxTokens {
            defaults.set(backgroundMaxTokens, forKey: Self.backgroundMaxTokensKey)
        } else {
            defaults.removeObject(forKey: Self.backgroundMaxTokensKey)
        }
        if let backgroundTextReasoningEffort {
            defaults.set(backgroundTextReasoningEffort.rawValue, forKey: Self.backgroundEffortKey)
        } else {
            defaults.removeObject(forKey: Self.backgroundEffortKey)
        }
        defaults.set(
            backgroundExtraBody.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.backgroundExtraBodyKey
        )
        try Self.store(apiKey, account: Self.keychainAccount)
        try Self.store(backgroundAPIKey, account: Self.backgroundKeychainAccount)
        defaults.set(judgeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.judgeBaseURLKey)
        defaults.set(judgeModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.judgeModelKey)
        defaults.set(judgeExtraBody.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.judgeExtraBodyKey)
        try Self.store(judgeAPIKey, account: JudgeService.chat.keychainAccount)
        defaults.set(retrievalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.retrievalBaseURLKey)
        defaults.set(embeddingProvider.rawValue, forKey: Self.embeddingProviderKey)
        defaults.set(embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.embeddingModelKey)
        if let embeddingDimensions {
            defaults.set(embeddingDimensions, forKey: Self.embeddingDimensionsKey)
        } else {
            defaults.removeObject(forKey: Self.embeddingDimensionsKey)
        }
        defaults.set(rerankModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.rerankModelKey)
        try Self.store(retrievalAPIKey, account: Self.retrievalKeychainAccount)
        try Self.store(geminiAPIKey, account: Self.geminiKeychainAccount)
        defaults.set(
            geminiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.geminiBaseURLKey
        )
        defaults.set(reachOutHours, forKey: Self.reachOutHoursKey)
        defaults.set(reachOutByTier, forKey: Self.reachOutByTierKey)
        defaults.set(tracingEnabled, forKey: Self.tracingEnabledKey)
        defaults.set(traceRetention, forKey: Self.traceRetentionKey)
        defaults.set(speechToText.rawValue, forKey: Self.speechToTextKey)
        defaults.set(sonioxModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.sonioxModelKey)
        defaults.set(
            bailianSTTModel.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: Self.bailianSTTModelKey
        )
        defaults.set(fishModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.fishModelKey)
        defaults.set(max(0, callMinutes), forKey: Self.callMinutesKey)
        defaults.set(max(0, callTurns), forKey: Self.callTurnsKey)
        defaults.set(phoneTexture, forKey: Self.phoneTextureKey)
        try Self.store(sonioxAPIKey, account: Self.sonioxKeychainAccount)
        try Self.store(dashscopeAPIKey, account: Self.dashscopeKeychainAccount)
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
        if let emotionMinProbability {
            defaults.set(emotionMinProbability, forKey: Self.emotionMinProbabilityKey)
        } else {
            defaults.removeObject(forKey: Self.emotionMinProbabilityKey)
        }
        defaults.set(Self.reasonableTimeout(emotionTimeout), forKey: Self.emotionTimeoutKey)
    }

    /// A timeout short enough to be useful and long enough to reach the service: anything
    /// that is not a finite number in the judge's range (`Task.sleep` traps on `1e30`)
    /// becomes the default, so a stored value from an older build cannot crash a call.
    private static func reasonableTimeout(_ seconds: Double) -> Double {
        SystemOneSegmentEmotionJudge.timeoutRange.contains(seconds)
            ? seconds
            : SystemOneSegmentEmotionJudge.defaultTimeout
    }

    /// Applies the values an imported `.env` carries; a nil value leaves the setting as
    /// it was. The caller saves afterwards.
    mutating func apply(_ values: EnvAPISettings) {
        if let value = values.chatProtocol { apiProtocol = value }
        if let value = values.chatBaseURL { baseURL = value }
        if let value = values.chatAPIKey { apiKey = value }
        if let value = values.chatModel { model = value }
        if let value = values.chatMaxTokens { maxTokens = value }
        if let value = values.chatReasoningEffort { textReasoningEffort = value }
        if let value = values.chatCallReasoningEffort { callReasoningEffort = value }
        if let value = values.chatExtraBody { extraBody = Self.jsonText(value) }

        if let value = values.backgroundProtocol { backgroundProtocol = value }
        if let value = values.backgroundBaseURL { backgroundBaseURL = value }
        if let value = values.backgroundAPIKey { backgroundAPIKey = value }
        if let value = values.backgroundModel { backgroundModel = value }
        if let value = values.backgroundMaxTokens { backgroundMaxTokens = value }
        if let value = values.backgroundReasoningEffort {
            backgroundTextReasoningEffort = value
        }
        if let value = values.backgroundExtraBody {
            backgroundExtraBody = Self.jsonText(value)
        }

        if let value = values.judgeService { judgeService = value }
        if let value = values.jevAPIKey { jevAPIKey = value }
        if let value = values.jevModel { jevModel = value }
        if let value = values.jevBaseURL { jevBaseURL = value }
        if let value = values.cloudflareAPIKey { cloudflareAPIKey = value }
        if let value = values.cloudflareAccountID { cloudflareAccountID = value }
        if let value = values.cloudflareModel { cloudflareModel = value }
        if let value = values.bailianJudgeAPIKey { bailianAPIKey = value }
        if let value = values.bailianWorkspace { bailianWorkspace = value }
        if let value = values.bailianRegion { bailianRegion = value }
        if let value = values.bailianModel { bailianModel = value }
        if let value = values.emotionMinProbability { emotionMinProbability = value }
        if let value = values.emotionTimeout { emotionTimeout = value }

        if let value = values.siliconflowAPIKey { retrievalAPIKey = value }
        if let value = values.siliconflowBaseURL { retrievalBaseURL = value }
        if let value = values.embeddingService { embeddingProvider = value }
        if let value = values.embeddingModel { embeddingModel = value }
        if let value = values.embeddingDimensions { embeddingDimensions = value }
        if let value = values.rerankModel { rerankModel = value }
        if let value = values.geminiAPIKey { geminiAPIKey = value }
        if let value = values.geminiBaseURL { geminiBaseURL = value }

        if let value = values.speechToText { speechToText = value }
        if let value = values.sonioxAPIKey { sonioxAPIKey = value }
        if let value = values.dashscopeAPIKey { dashscopeAPIKey = value }
        if let value = values.bailianSTTModel { bailianSTTModel = value }
        if let value = values.fishAPIKey { fishAPIKey = value }
        if let value = values.fishModel { fishModel = value }

        // DeepSeek serves its Anthropic surface under /anthropic; an upstream `.env`
        // written for the OpenAI surfaces names only the root.
        baseURL = APIServiceRouting.baseURLForImportedSettings(baseURL, protocol: apiProtocol)
    }

    /// The recognizer chosen, and whether its key is filled in: the call needs both.
    var recognitionKey: String {
        switch speechToText {
        case .soniox: sonioxAPIKey
        case .bailian: dashscopeAPIKey
        }
    }

    var recognitionIsConfigured: Bool {
        !recognitionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func jsonText(_ value: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Model configs

    /// The provider config for typed turns, or nil while something still has to be filled
    /// in.
    var config: ChatModelConfig? {
        modelConfig(reasoningEffort: textReasoningEffort)
    }

    /// What a call's turns use: the same model, with the call's own thinking effort.
    var callConfig: ChatModelConfig? {
        modelConfig(reasoningEffort: callReasoningEffort)
    }

    private func modelConfig(reasoningEffort: ReasoningEffort?) -> ChatModelConfig? {
        let base = APIServiceRouting.baseURLForImportedSettings(baseURL, protocol: apiProtocol)
        guard let url = Self.url(base),
              let name = Self.value(model),
              let key = Self.value(apiKey),
              let extra = Self.extra(extraBody)
        else { return nil }
        return ChatModelConfig(
            baseURL: url,
            model: name,
            apiKey: key,
            historyTurns: historyTurns,
            maxTokens: maxTokens,
            apiProtocol: apiProtocol,
            reasoningEffort: reasoningEffort,
            extraBody: extra
        )
    }

    var isConfigured: Bool { config != nil }

    /// The background model as the producer wrote it, before the empty fields fall back.
    var background: BackgroundChatConfig? {
        // Nil and unusable extra JSON both make the background model unusable; blank is
        // no extra body.
        guard let extra = Self.extra(backgroundExtraBody) else { return nil }
        let base = APIServiceRouting.baseURLForImportedSettings(
            backgroundBaseURL,
            protocol: backgroundProtocol ?? apiProtocol
        )
        return BackgroundChatConfig(
            apiProtocol: backgroundProtocol,
            baseURL: Self.url(base),
            model: Self.value(backgroundModel),
            apiKey: Self.value(backgroundAPIKey),
            maxTokens: backgroundMaxTokens,
            reasoningEffort: backgroundTextReasoningEffort,
            extraBody: extra
        )
    }

    /// Whether the producer filled in any background field.
    var hasBackgroundModel: Bool {
        backgroundProtocol != nil
            || !backgroundBaseURL.trimmed.isEmpty
            || !backgroundModel.trimmed.isEmpty
            || !backgroundAPIKey.trimmed.isEmpty
            || backgroundMaxTokens != nil
            || backgroundTextReasoningEffort != nil
            || !backgroundExtraBody.trimmed.isEmpty
    }

    /// Memories and titles: the background model with the chat model's missing fields, or
    /// the chat model itself when the background model is blank. Without a chat model the
    /// background model has to be complete on its own — the placeholder never supplies an
    /// address for a real request.
    var backgroundConfig: ChatModelConfig? {
        guard let background, background.isEnabled else { return config }
        if let config { return background.config(inheriting: config) }
        guard background.baseURL != nil,
              background.model != nil,
              background.apiKey != nil
        else { return nil }
        return background.config(inheriting: .placeholder)
    }

    /// The judge's config: its own when filled in, else the chat model's. The chat judge is
    /// always chat-completions, so it never silently inherits a Responses or Anthropic
    /// chat model (spec #80).
    func judgeConfig(chat: ChatModelConfig?) -> JudgeConfig? {
        if let url = Self.url(judgeBaseURL),
           let name = Self.value(judgeModel),
           let key = Self.value(judgeAPIKey),
           let extra = Self.extra(judgeExtraBody)
        {
            return JudgeConfig(baseURL: url, model: name, apiKey: key, extraBody: extra)
        }
        guard apiProtocol == .chatCompletions, let chat else { return nil }
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

    // MARK: - Retrieval

    /// Which embedding service the content bundle names, or the setting before a bundle.
    func retrievalService(for bundle: ContentEmbeddingSpace?) -> EmbeddingService {
        bundle?.service ?? embeddingProvider
    }

    /// The embedding config the installed bundle asks for, or the setting before one.
    /// Nil without the service's key.
    func retrievalEmbeddingConfig(for bundle: ContentEmbeddingSpace?) -> RetrievalEmbeddingConfig? {
        let service = retrievalService(for: bundle)
        switch service {
        case .siliconflow:
            guard let key = Self.value(retrievalAPIKey) else { return nil }
            let model = bundle?.model ?? Self.value(embeddingModel)
                ?? EmbeddingService.defaultSiliconFlowModel
            let base = APIServiceRouting.retrievalBaseURL(retrievalBaseURL)
            guard let url = URL(string: base) else { return nil }
            return .siliconFlow(EmbeddingConfig(baseURL: url, model: model, apiKey: key))
        case .gemini:
            guard let key = Self.value(geminiAPIKey) else { return nil }
            let model = bundle?.model ?? Self.value(embeddingModel)
                ?? EmbeddingService.defaultGeminiModel
            let dimensions = bundle?.dimensions ?? embeddingDimensions ?? 1536
            let base = Self.value(geminiBaseURL)
                ?? "https://generativelanguage.googleapis.com/v1beta"
            guard let url = URL(string: base) else { return nil }
            return .gemini(GeminiEmbeddingConfig(
                baseURL: url,
                model: model,
                apiKey: key,
                dimensions: dimensions
            ))
        }
    }

    /// The embedding config before a bundle, for older callers.
    var embeddingConfig: RetrievalEmbeddingConfig? {
        retrievalEmbeddingConfig(for: nil)
    }

    var rerankConfig: RerankConfig? {
        guard let url = Self.url(retrievalBaseURL)
            ?? URL(string: APIServiceRouting.siliconFlowBaseURL),
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
        let trimmed = text.trimmed
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
        do {
            return .some(try ChatRequestExtras.decode(trimmed))
        } catch {
            return nil
        }
    }
}

private extension ChatModelConfig {
    /// Stands in for the chat model while resolving a background config that has every
    /// required field of its own; never used to call.
    static let placeholder = ChatModelConfig(
        baseURL: URL(string: "https://placeholder.invalid")!,
        model: "",
        apiKey: ""
    )
}
