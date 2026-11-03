import Foundation

/// The vector space the installed content bundle was made in. The bundle is the authority
/// for which embedding model retrieval uses; the query vector must live in the same space.
public struct ContentEmbeddingSpace: Sendable, Hashable {
    public var model: String
    public var dimensions: Int

    public init(model: String, dimensions: Int) {
        self.model = model
        self.dimensions = dimensions
    }

    /// Which service makes that model. Gemini has a client of its own, still to come
    /// (#89); until then a bundle made with it keeps retrieval off.
    public var service: EmbeddingService { EmbeddingService(model: model) }
}

public enum EmbeddingService: String, Sendable, Codable, CaseIterable, Identifiable {
    case siliconflow
    case gemini

    public var id: String { rawValue }

    public init(model: String) {
        self = model.lowercased().hasPrefix("gemini") ? .gemini : .siliconflow
    }

    public var title: String {
        switch self {
        case .siliconflow: "硅基流动"
        case .gemini: "Google Gemini"
        }
    }

    public static let defaultSiliconFlowModel = "Qwen/Qwen3-Embedding-0.6B"
    public static let defaultGeminiModel = "gemini-embedding-2"
}

public enum SpeechToTextService: String, Sendable, Codable, CaseIterable, Identifiable {
    case soniox
    case bailian

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .soniox: "Soniox"
        case .bailian: "阿里云百炼"
        }
    }
}

// MARK: - Parsing

public struct EnvParseIssue: Sendable, Hashable {
    public var line: Int
    public var text: String
    public var reason: String

    public init(line: Int, text: String, reason: String) {
        self.line = line
        self.text = text
        self.reason = reason
    }
}

public struct EnvEntry: Sendable, Hashable {
    public var key: String
    public var value: String
    public var line: Int

    public init(key: String, value: String, line: Int) {
        self.key = key
        self.value = value
        self.line = line
    }
}

public struct EnvFile: Sendable, Hashable {
    public var entries: [EnvEntry]
    public var issues: [EnvParseIssue]

    public init(entries: [EnvEntry], issues: [EnvParseIssue]) {
        self.entries = entries
        self.issues = issues
    }
}

public enum EnvFileError: LocalizedError, Equatable {
    case notUTF8
    case tooLarge
    case empty

    public var errorDescription: String? {
        switch self {
        case .notUTF8: "这个文件不是 UTF-8 文本，读不出 .env"
        case .tooLarge: "这个文件太大了，.env 一般只有几 KB"
        case .empty: "这个文件里没有可识别的配置项"
        }
    }
}

/// Reads upstream's `.env` shape: `KEY=VALUE`, `export KEY=VALUE`, `#` comments, blank
/// lines, and single- or double-quoted values. Variables are not expanded; a line that
/// cannot be read is listed and skipped, never stopping the rest.
public enum EnvParser {
    public static let maxBytes = 256 * 1024

    public static func parse(data: Data) throws -> EnvFile {
        guard data.count <= maxBytes else { throw EnvFileError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EnvFileError.notUTF8
        }
        return parse(text: text)
    }

    public static func parse(text: String) -> EnvFile {
        var entries: [EnvEntry] = []
        var issues: [EnvParseIssue] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, raw) in lines.enumerated() {
            let number = index + 1
            var line = raw.trimmingCharacters(in: .whitespaces)
            if index == 0, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") || line.hasPrefix("export\t") {
                line = String(line.dropFirst("export".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let equals = line.firstIndex(of: "=") else {
                issues.append(.init(line: number, text: String(raw), reason: "缺少「=」"))
                continue
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard isValid(key) else {
                issues.append(.init(line: number, text: String(raw), reason: "键名只能包含字母、数字和下划线"))
                continue
            }
            let value = unquoted(String(line[line.index(after: equals)...]))
            entries.append(.init(key: key, value: value, line: number))
        }
        return EnvFile(entries: entries, issues: issues)
    }

    private static func isValid(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func unquoted(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let first = value.first, first == "'" || first == "\"" else {
            return value
        }
        guard value.last == first else { return value }
        let inner = String(value.dropFirst().dropLast())
        if first == "'" { return inner }
        return inner
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

// MARK: - Mapping

/// The values an iOS build can take from upstream's `.env`, each optional: a key that is
/// absent or blank leaves the setting as it was.
public struct EnvAPISettings: Sendable, Hashable {
    public var chatProtocol: ChatProtocol?
    public var chatBaseURL: String?
    public var chatAPIKey: String?
    public var chatModel: String?
    public var chatMaxTokens: Int?
    public var chatReasoningEffort: ReasoningEffort?
    public var chatCallReasoningEffort: ReasoningEffort?
    public var chatExtraBody: [String: JSONValue]?

    public var backgroundProtocol: ChatProtocol?
    public var backgroundBaseURL: String?
    public var backgroundAPIKey: String?
    public var backgroundModel: String?
    public var backgroundMaxTokens: Int?
    public var backgroundReasoningEffort: ReasoningEffort?
    public var backgroundExtraBody: [String: JSONValue]?

    public var judgeService: JudgeService?
    public var jevAPIKey: String?
    public var jevModel: String?
    public var jevBaseURL: String?
    public var cloudflareAPIKey: String?
    public var cloudflareAccountID: String?
    public var cloudflareModel: String?
    public var bailianJudgeAPIKey: String?
    public var bailianWorkspace: String?
    public var bailianRegion: BailianRegion?
    public var bailianModel: String?
    public var emotionMinProbability: Double?
    public var emotionTimeout: Double?

    public var siliconflowAPIKey: String?
    public var siliconflowBaseURL: String?
    public var embeddingService: EmbeddingService?
    public var embeddingModel: String?
    public var embeddingDimensions: Int?
    public var rerankModel: String?
    public var geminiAPIKey: String?
    public var geminiBaseURL: String?

    public var speechToText: SpeechToTextService?
    public var sonioxAPIKey: String?
    public var fishAPIKey: String?
    public var fishModel: String?

    public init() {}
}

public struct EnvMappedEntry: Sendable, Hashable {
    public var key: String
    public var label: String
    public var secret: Bool

    public init(key: String, label: String, secret: Bool) {
        self.key = key
        self.label = label
        self.secret = secret
    }
}

public struct EnvValueIssue: Sendable, Hashable {
    public var key: String
    public var line: Int
    public var message: String

    public init(key: String, line: Int, message: String) {
        self.key = key
        self.line = line
        self.message = message
    }
}

public struct EnvImportReport: Sendable {
    public var values: EnvAPISettings
    /// The keys that will be applied, in file order, once per key.
    public var mapped: [EnvMappedEntry]
    /// Keys upstream's example has but this app does not read yet.
    public var unsupported: [EnvEntry]
    /// Keys that are not in upstream's example at all.
    public var unknown: [EnvEntry]
    public var malformed: [EnvParseIssue]
    /// Values that were recognized but cannot be used; those keys are not applied.
    public var invalid: [EnvValueIssue]
    /// Same setting from more than one key, or a value that would not match the content
    /// bundle.
    public var conflicts: [EnvValueIssue]

    public init(values: EnvAPISettings, mapped: [EnvMappedEntry], unsupported: [EnvEntry],
                unknown: [EnvEntry], malformed: [EnvParseIssue],
                invalid: [EnvValueIssue], conflicts: [EnvValueIssue]) {
        self.values = values
        self.mapped = mapped
        self.unsupported = unsupported
        self.unknown = unknown
        self.malformed = malformed
        self.invalid = invalid
        self.conflicts = conflicts
    }

    public var hasValues: Bool { !mapped.isEmpty }

    public var blockingError: EnvFileError? {
        hasValues || !invalid.isEmpty || !malformed.isEmpty ? nil : .empty
    }
}

/// Maps a parsed file onto the API settings iOS knows. The classification follows
/// upstream's example: a key the example has but iOS does not support is 暂不支持; a key
/// the example does not have is 未识别.
public enum EnvImporter {
    public static func map(
        _ file: EnvFile,
        contentEmbedding: ContentEmbeddingSpace? = nil
    ) -> EnvImportReport {
        var values = EnvAPISettings()
        var mapped: [EnvMappedEntry] = []
        var unsupported: [EnvEntry] = []
        var unknown: [EnvEntry] = []
        var invalid: [EnvValueIssue] = []
        var conflicts: [EnvValueIssue] = []

        // A repeated key is read once, the last line winning, and said so.
        var seen: [String: Int] = [:]
        var entries: [EnvEntry] = []
        for entry in file.entries {
            if let first = seen[entry.key] {
                conflicts.append(.init(
                    key: entry.key,
                    line: entry.line,
                    message: "第 \(first) 行已经出现过，这次用最后一行的值"
                ))
            } else {
                seen[entry.key] = entry.line
            }
            entries.append(entry)
        }
        // Last occurrence wins: keep the final entry for each key.
        var last: [String: EnvEntry] = [:]
        var order: [String] = []
        for entry in entries {
            if last[entry.key] == nil { order.append(entry.key) }
            last[entry.key] = entry
        }

        func note(_ key: String, _ label: String, secret: Bool = false) {
            mapped.append(.init(key: key, label: label, secret: secret))
        }

        func text(_ key: String) -> String? {
            guard let entry = last[key] else { return nil }
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func integer(_ key: String, positive: Bool = true) -> Int? {
            guard let raw = text(key), let entry = last[key] else { return nil }
            guard let value = Int(raw), !positive || value > 0 else {
                invalid.append(.init(
                    key: key,
                    line: entry.line,
                    message: positive ? "需要是正整数" : "需要是整数"
                ))
                return nil
            }
            return value
        }

        func number(_ key: String, in range: ClosedRange<Double>) -> Double? {
            guard let raw = text(key), let entry = last[key] else { return nil }
            guard let value = Double(raw), range.contains(value) else {
                invalid.append(.init(
                    key: key,
                    line: entry.line,
                    message: "需要在 \(range.lowerBound) 到 \(range.upperBound) 之间"
                ))
                return nil
            }
            return value
        }

        func protocolValue(_ key: String) -> ChatProtocol? {
            guard let raw = text(key), let entry = last[key] else { return nil }
            guard let value = ChatProtocol(rawValue: raw.lowercased()) else {
                invalid.append(.init(
                    key: key,
                    line: entry.line,
                    message: "只能是 chat-completions、responses 或 anthropic"
                ))
                return nil
            }
            return value
        }

        func effort(_ key: String) -> ReasoningEffort? {
            guard let raw = text(key), let entry = last[key] else { return nil }
            guard let value = ReasoningEffort.parse(raw) else {
                invalid.append(.init(
                    key: key,
                    line: entry.line,
                    message: "只能是 none、minimal、low、medium、high、xhigh 或 max"
                ))
                return nil
            }
            return value
        }

        func extras(_ key: String) -> [String: JSONValue]? {
            guard let raw = text(key), let entry = last[key] else { return nil }
            do {
                return try ChatRequestExtras.decode(raw)
            } catch {
                invalid.append(.init(
                    key: key,
                    line: entry.line,
                    message: error.localizedDescription
                ))
                return nil
            }
        }

        for key in order {
            guard let entry = last[key] else { continue }
            switch key {
            case "CHAT_LLM_PROTOCOL":
                values.chatProtocol = protocolValue(key)
                if values.chatProtocol != nil { note(key, "对话协议") }
            case "CHAT_LLM_BASE_URL":
                values.chatBaseURL = text(key)
                if values.chatBaseURL != nil { note(key, "对话接口地址") }
            case "CHAT_LLM_API_KEY":
                values.chatAPIKey = text(key)
                if values.chatAPIKey != nil { note(key, "对话密钥", secret: true) }
            case "CHAT_LLM_MODEL":
                values.chatModel = text(key)
                if values.chatModel != nil { note(key, "对话模型") }
            case "CHAT_LLM_MAX_TOKENS":
                values.chatMaxTokens = integer(key)
                if values.chatMaxTokens != nil { note(key, "对话 max tokens") }
            case "CHAT_LLM_REASONING_EFFORT":
                values.chatReasoningEffort = effort(key)
                if values.chatReasoningEffort != nil { note(key, "文字对话思考强度") }
            case "CHAT_LLM_CALL_REASONING_EFFORT":
                values.chatCallReasoningEffort = effort(key)
                if values.chatCallReasoningEffort != nil { note(key, "通话思考强度") }
            case "CHAT_LLM_EXTRA_BODY":
                values.chatExtraBody = extras(key)
                if values.chatExtraBody != nil { note(key, "对话额外参数") }

            case "BACKGROUND_LLM_PROTOCOL":
                values.backgroundProtocol = protocolValue(key)
                if values.backgroundProtocol != nil { note(key, "后台模型协议") }
            case "BACKGROUND_LLM_BASE_URL":
                values.backgroundBaseURL = text(key)
                if values.backgroundBaseURL != nil { note(key, "后台模型接口地址") }
            case "BACKGROUND_LLM_API_KEY":
                values.backgroundAPIKey = text(key)
                if values.backgroundAPIKey != nil { note(key, "后台模型密钥", secret: true) }
            case "BACKGROUND_LLM_MODEL":
                values.backgroundModel = text(key)
                if values.backgroundModel != nil { note(key, "后台模型") }
            case "BACKGROUND_LLM_MAX_TOKENS":
                values.backgroundMaxTokens = integer(key)
                if values.backgroundMaxTokens != nil { note(key, "后台模型 max tokens") }
            case "BACKGROUND_LLM_REASONING_EFFORT":
                values.backgroundReasoningEffort = effort(key)
                if values.backgroundReasoningEffort != nil { note(key, "后台模型思考强度") }
            case "BACKGROUND_LLM_EXTRA_BODY":
                values.backgroundExtraBody = extras(key)
                if values.backgroundExtraBody != nil { note(key, "后台模型额外参数") }

            case "JUDGE_PROVIDER":
                if let raw = text(key) {
                    guard let service = JudgeService(rawValue: raw.lowercased()),
                          service != .chat
                    else {
                        invalid.append(.init(
                            key: key,
                            line: entry.line,
                            message: "只能是 jev、cloudflare 或 bailian"
                        ))
                        continue
                    }
                    values.judgeService = service
                    note(key, "判断服务")
                }
            case "JEV_API_KEY":
                values.jevAPIKey = text(key)
                if values.jevAPIKey != nil { note(key, "Jev 密钥", secret: true) }
            case "JEV_MODEL":
                values.jevModel = text(key)
                if values.jevModel != nil { note(key, "Jev 模型") }
            case "JEV_BASE_URL":
                values.jevBaseURL = text(key)
                if values.jevBaseURL != nil { note(key, "Jev 接口地址") }
            case "CLOUDFLARE_API_TOKEN":
                values.cloudflareAPIKey = text(key)
                if values.cloudflareAPIKey != nil { note(key, "Cloudflare 密钥", secret: true) }
            case "CLOUDFLARE_ACCOUNT_ID":
                values.cloudflareAccountID = text(key)
                if values.cloudflareAccountID != nil { note(key, "Cloudflare 账号 ID") }
            case "CLOUDFLARE_JUDGE_MODEL":
                values.cloudflareModel = text(key)
                if values.cloudflareModel != nil { note(key, "Cloudflare 模型") }
            case "BAILIAN_JUDGE_API_KEY":
                values.bailianJudgeAPIKey = text(key)
                if values.bailianJudgeAPIKey != nil { note(key, "百炼判断密钥", secret: true) }
            case "BAILIAN_JUDGE_WORKSPACE_ID":
                values.bailianWorkspace = text(key)
                if values.bailianWorkspace != nil { note(key, "百炼业务空间 ID") }
            case "BAILIAN_JUDGE_REGION":
                if let raw = text(key) {
                    guard let region = BailianRegion(rawValue: raw.lowercased()) else {
                        invalid.append(.init(
                            key: key,
                            line: entry.line,
                            message: "只能是 beijing 或 singapore"
                        ))
                        continue
                    }
                    values.bailianRegion = region
                    note(key, "百炼地域")
                }
            case "BAILIAN_JUDGE_MODEL":
                values.bailianModel = text(key)
                if values.bailianModel != nil { note(key, "百炼判断模型") }
            case "JUDGE_EMOTION_MIN_PROBABILITY":
                values.emotionMinProbability = number(key, in: 0...1)
                if values.emotionMinProbability != nil { note(key, "情绪最低概率") }
            case "JUDGE_EMOTION_TIMEOUT":
                values.emotionTimeout = number(
                    key,
                    in: SystemOneSegmentEmotionJudge.timeoutRange
                )
                if values.emotionTimeout != nil { note(key, "情绪判断超时") }

            case "SILICONFLOW_API_KEY":
                values.siliconflowAPIKey = text(key)
                if values.siliconflowAPIKey != nil { note(key, "检索密钥", secret: true) }
            case "SILICONFLOW_BASE_URL":
                values.siliconflowBaseURL = text(key)
                if values.siliconflowBaseURL != nil { note(key, "检索接口地址") }
            case "EMBEDDING_PROVIDER":
                if let raw = text(key) {
                    let service = EmbeddingService(rawValue: raw.lowercased())
                    guard let service else {
                        invalid.append(.init(
                            key: key,
                            line: entry.line,
                            message: "只能是 siliconflow 或 gemini"
                        ))
                        continue
                    }
                    if let contentEmbedding, contentEmbedding.service != service {
                        conflicts.append(.init(
                            key: key,
                            line: entry.line,
                            message: "内容包用的是 \(contentEmbedding.service.title) 的向量，"
                                + "不能换成 \(service.title)"
                        ))
                    } else {
                        values.embeddingService = service
                        note(key, "向量化服务")
                    }
                }
            case "EMBEDDING_MODEL":
                guard let model = text(key) else { break }
                if let contentEmbedding, model != contentEmbedding.model {
                    conflicts.append(.init(
                        key: key,
                        line: entry.line,
                        message: "内容包用的是 \(contentEmbedding.model)，与这个值不一致；"
                            + "换模型要先用上游工具重新向量化并重新导出内容包"
                    ))
                } else {
                    values.embeddingModel = model
                    note(key, "向量化模型")
                }
            case "EMBEDDING_DIMENSIONS":
                guard let dimensions = integer(key) else { break }
                if let contentEmbedding, dimensions != contentEmbedding.dimensions {
                    conflicts.append(.init(
                        key: key,
                        line: entry.line,
                        message: "内容包的向量维度是 \(contentEmbedding.dimensions)，与这个值不一致"
                    ))
                } else {
                    values.embeddingDimensions = dimensions
                    note(key, "向量维度")
                }
            case "RERANK_MODEL":
                values.rerankModel = text(key)
                if values.rerankModel != nil { note(key, "重排模型") }
            case "GEMINI_API_KEY":
                values.geminiAPIKey = text(key)
                if values.geminiAPIKey != nil { note(key, "Gemini 密钥", secret: true) }
            case "GEMINI_BASE_URL":
                values.geminiBaseURL = text(key)
                if values.geminiBaseURL != nil { note(key, "Gemini 接口地址") }

            case "STT_PROVIDER":
                if let raw = text(key) {
                    if raw.lowercased() == SpeechToTextService.soniox.rawValue {
                        // Soniox is the only recognizer in this build; nothing changes.
                        values.speechToText = .soniox
                    } else if raw.lowercased() == SpeechToTextService.bailian.rawValue {
                        unsupported.append(entry)
                    } else {
                        invalid.append(.init(
                            key: key,
                            line: entry.line,
                            message: "只能是 soniox 或 bailian"
                        ))
                    }
                }
            case "SONIOX_API_KEY":
                values.sonioxAPIKey = text(key)
                if values.sonioxAPIKey != nil { note(key, "Soniox 密钥", secret: true) }
            case "FISH_AUDIO_API_KEY":
                values.fishAPIKey = text(key)
                if values.fishAPIKey != nil { note(key, "Fish Audio 密钥", secret: true) }
            case "FISH_AUDIO_MODEL":
                values.fishModel = text(key)
                if values.fishModel != nil { note(key, "Fish Audio 模型") }

            default:
                if isUnsupported(key) {
                    unsupported.append(entry)
                } else {
                    unknown.append(entry)
                }
            }
        }

        // Anthropic has no `minimal`; a file that pairs them is refused, not half-applied.
        let effectiveChatProtocol = values.chatProtocol
        if effectiveChatProtocol == .anthropic, values.chatReasoningEffort == .minimal,
           let entry = last["CHAT_LLM_REASONING_EFFORT"] {
            invalid.append(.init(
                key: "CHAT_LLM_REASONING_EFFORT",
                line: entry.line,
                message: "Anthropic 接口没有 minimal"
            ))
            values.chatReasoningEffort = nil
        }
        let effectiveBackgroundProtocol = values.backgroundProtocol
            ?? values.chatProtocol
        if effectiveBackgroundProtocol == .anthropic,
           values.backgroundReasoningEffort == .minimal,
           let entry = last["BACKGROUND_LLM_REASONING_EFFORT"] {
            invalid.append(.init(
                key: "BACKGROUND_LLM_REASONING_EFFORT",
                line: entry.line,
                message: "Anthropic 接口没有 minimal"
            ))
            values.backgroundReasoningEffort = nil
        }

        return EnvImportReport(
            values: values,
            mapped: mapped,
            unsupported: unsupported,
            unknown: unknown,
            malformed: file.issues,
            invalid: invalid,
            conflicts: conflicts
        )
    }

    private static let unsupportedKeys: Set<String> = [
        "BAILIAN_STT_MODEL",
        "RERANK_MIN_RELEVANCE",
        "RERANK_MEMORY_MIN_RELEVANCE",
        "GEMINI_BILLING_ENABLED",
    ]

    private static let unsupportedPrefixes = [
        "EIDOLON_", "NOVELAI_", "GPT_IMAGE_", "DASHSCOPE_",
        "QWEATHER_", "GITHUB_", "GOOGLE_",
    ]

    private static func isUnsupported(_ key: String) -> Bool {
        unsupportedKeys.contains(key) || unsupportedPrefixes.contains { key.hasPrefix($0) }
    }
}
