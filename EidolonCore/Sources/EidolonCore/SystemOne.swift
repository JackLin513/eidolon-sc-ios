import Foundation

/// The judge model families upstream calibrated thresholds for. Each is sure of itself
/// in its own way, so each has thresholds of its own (upstream `JudgeFamily`).
public enum JudgeFamily: String, Sendable, Hashable, CaseIterable {
    case jev
    case clef
    case clefFlash = "clef-flash"
    case decisionModel = "decision-model"
}

/// The probabilities at or above which a yes-or-no answer counts as yes.
public struct JudgeThresholds: Sendable, Hashable {
    public var needsRetrieval: Double
    public var recall: Double
    public var aboutProducer: Double
    /// The likeliest emotion's probability at or above which she shows it, and the
    /// likeliest nod's at or above which she nods or shakes her head (spec「情绪判断」).
    public var emotion: Double
    public var outOfLine: Double
    public var manipulation: Double

    public init(
        needsRetrieval: Double,
        recall: Double,
        aboutProducer: Double,
        emotion: Double,
        outOfLine: Double,
        manipulation: Double
    ) {
        self.needsRetrieval = needsRetrieval
        self.recall = recall
        self.aboutProducer = aboutProducer
        self.emotion = emotion
        self.outOfLine = outOfLine
        self.manipulation = manipulation
    }
}

/// Which family a model belongs to, and the thresholds it judges by. Copied from
/// upstream `judge.py`, including Jev's for a model of none of the known families.
public enum JudgeFamilies {
    public static let fallback: JudgeFamily = .jev

    /// The family of `model`, named as any service names it (`typesafe/jev-1.13`,
    /// `cloudflare/clef-flash`, `clef`); nil for a model of none of them.
    public static func family(of model: String) -> JudgeFamily? {
        let name = model.split(separator: "/").last.map(String.init)?.lowercased() ?? model.lowercased()
        if name == "clef" { return .clef }
        if name == "clef-flash" { return .clefFlash }
        if name == "jev" || name.hasPrefix("jev-") { return .jev }
        if name == "decision-model" || name.hasPrefix("decision-model-") { return .decisionModel }
        return nil
    }

    public static func thresholds(of family: JudgeFamily) -> JudgeThresholds {
        switch family {
        case .jev:
            return JudgeThresholds(
                needsRetrieval: 0.5, recall: 0.5, aboutProducer: 0.5,
                emotion: 0.5, outOfLine: 0.7, manipulation: 0.4
            )
        case .clef:
            return JudgeThresholds(
                needsRetrieval: 0.5, recall: 0.8, aboutProducer: 0.1,
                emotion: 0.4, outOfLine: 0.5, manipulation: 0.5
            )
        case .clefFlash:
            return JudgeThresholds(
                needsRetrieval: 0.5, recall: 0.7, aboutProducer: 0.3,
                emotion: 0.4, outOfLine: 0.6, manipulation: 0.6
            )
        case .decisionModel:
            return JudgeThresholds(
                needsRetrieval: 0.06, recall: 0.8, aboutProducer: 0.1,
                emotion: 0.4, outOfLine: 0.3, manipulation: 0.4
            )
        }
    }

    /// The thresholds `model` judges by; Jev's for a model not known.
    public static func thresholds(for model: String) -> JudgeThresholds {
        thresholds(of: family(of: model) ?? fallback)
    }
}

/// A model of no known family is read by Jev's thresholds anyway (upstream
/// `JudgeFamilies`); the note says so wherever the producer can see the judge.
public enum JudgeCalibration {
    public static let uncalibratedNote = "这个模型没有校准，按 Jev 的阈值算"
}

/// Alibaba Cloud Model Studio's regions, as its host names them.
public enum BailianRegion: String, Sendable, Hashable, CaseIterable, Codable {
    case beijing
    case singapore

    public var code: String {
        switch self {
        case .beijing: "cn-beijing"
        case .singapore: "ap-southeast-1"
        }
    }

    public var title: String {
        switch self {
        case .beijing: "北京"
        case .singapore: "新加坡"
        }
    }
}

/// A Model Studio workspace: its id, its region, the judge model and the key. The address
/// is made from the workspace id and the region, as upstream `BailianJudgeSettings` does.
public struct BailianJudgeConfig: Sendable, Hashable {
    public var workspaceID: String
    public var region: BailianRegion
    public var model: String
    public var apiKey: String

    public init(
        workspaceID: String,
        region: BailianRegion = .beijing,
        model: String = "decision-model-preview",
        apiKey: String
    ) {
        self.workspaceID = workspaceID
        self.region = region
        self.model = model
        self.apiKey = apiKey
    }

    public var baseURL: URL? {
        let workspace = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else { return nil }
        return URL(
            string: "https://\(workspace).\(region.code).maas.aliyuncs.com/compatible-mode/v1"
        )
    }

    /// The System One endpoint: the base address, one trailing slash at most, `/systemone`.
    public var systemOneURL: URL? {
        guard let base = baseURL?.absoluteString else { return nil }
        return URL(string: (base.hasSuffix("/") ? base : base + "/") + "systemone")
    }

    /// What the provider needs, or nil while something is still missing.
    public var systemOne: SystemOneConfig? {
        guard let url = systemOneURL else { return nil }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !key.isEmpty else { return nil }
        return SystemOneConfig(baseURL: url, model: name, apiKey: key)
    }
}

/// Jev through TypeSafe's System One endpoint (`/systemone`, which OpenRouter, Vercel AI
/// Gateway and TypeSafe itself all serve alike). The address is the API base, not the
/// endpoint: `base_url.rstrip("/") + "/systemone"`, as upstream `JevJudge` does.
public struct JevJudgeConfig: Sendable, Hashable {
    public static let defaultBaseURL = "https://openrouter.ai/api/v1"
    public static let defaultModel = "typesafe/jev-1.13"

    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(
        baseURL: String = defaultBaseURL,
        model: String = defaultModel,
        apiKey: String
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    /// The System One endpoint: the base address without its trailing slashes, `/systemone`.
    public var systemOneURL: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        return URL(string: base + "/systemone")
    }

    /// What the provider needs, or nil while something is still missing.
    public var systemOne: SystemOneConfig? {
        guard let url = systemOneURL else { return nil }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !key.isEmpty else { return nil }
        return SystemOneConfig(baseURL: url, model: name, apiKey: key, service: "Jev")
    }
}

/// Clef and Clef-flash on Cloudflare Workers AI: System One's questions, but the model is
/// named by its bare name in the URL and the body, and the answers come inside Cloudflare's
/// envelope (upstream `CloudflareJudge`).
public struct CloudflareJudgeConfig: Sendable, Hashable {
    public static let defaultModel = "clef-flash"

    public var accountID: String
    public var model: String
    public var apiKey: String

    public init(accountID: String, model: String = defaultModel, apiKey: String) {
        self.accountID = accountID
        self.model = model
        self.apiKey = apiKey
    }

    /// The model as Workers AI names it: no `@cf/cloudflare/` or `cloudflare/` in front.
    public var bareModel: String {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["@cf/cloudflare/", "cloudflare/"] {
            if name.hasPrefix(prefix) {
                name.removeFirst(prefix.count)
                break
            }
        }
        return name
    }

    /// Workers AI's endpoint: the account id and the bare model name.
    public var systemOneURL: URL? {
        let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = bareModel
        guard !account.isEmpty, !name.isEmpty else { return nil }
        return URL(
            string: "https://api.cloudflare.com/client/v4/accounts/"
                + "\(account)/ai/run/@cf/cloudflare/\(name)"
        )
    }

    /// What the provider needs, or nil while something is still missing.
    public var systemOne: SystemOneConfig? {
        guard let url = systemOneURL else { return nil }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return SystemOneConfig(
            baseURL: url,
            model: bareModel,
            apiKey: key,
            service: "Cloudflare Workers AI",
            response: .cloudflare
        )
    }
}

/// How a System One service wraps its answers.
public enum SystemOneResponse: Sendable, Hashable {
    /// `{answers, usage}` at the top level, as Jev and Model Studio answer.
    case plain
    /// `{result: {answers, usage}, success, errors, messages}`, as Workers AI answers.
    case cloudflare
}

/// One judge service speaking System One: where it is, what it is called, and the key.
public struct SystemOneConfig: Sendable, Hashable {
    /// The endpoint, with `/systemone` already on it.
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    /// What the trace calls the service.
    public var service: String
    /// Upstream waits five seconds for the judge (`httpx.Timeout(5, connect=3)`).
    public var timeout: TimeInterval
    /// Where the answers sit in the response.
    public var response: SystemOneResponse

    public init(
        baseURL: URL,
        model: String,
        apiKey: String,
        service: String = "阿里云百炼",
        timeout: TimeInterval = 5,
        response: SystemOneResponse = .plain
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.service = service
        self.timeout = timeout
        self.response = response
    }

    public var thresholds: JudgeThresholds {
        JudgeFamilies.thresholds(for: model)
    }

    /// Whether `model` was calibrated at all, or is read by Jev's thresholds by fallback.
    public var isCalibrated: Bool {
        JudgeFamilies.family(of: model) != nil
    }
}

/// What carries a judge request. A URLSession by default; tests hand in a stub.
public protocol JudgeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionJudgeTransport: JudgeTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SystemOneError.invalidResponse("判断服务没有返回 HTTP 响应")
        }
        return (data, http)
    }
}

/// Why a judge could not be read, in words the producer can act on.
public enum SystemOneError: LocalizedError, Equatable {
    case timedOut
    case transport(String)
    case refused(status: Int, detail: String)
    case modelNotFound(String)
    case invalidResponse(String)
    /// Workers AI could not find the account: error codes 7000 and 7003, or a 404.
    case accountMismatch(String)
    /// Workers AI's 10,000 free neurons for the day are used up: error code 4006.
    case quotaExhausted(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "判断服务超时"
        case let .transport(detail):
            return "无法连接判断服务：\(detail)"
        case let .modelNotFound(detail):
            return "判断服务没有这个模型：\(detail)"
        case let .refused(status, detail):
            return "判断服务返回 \(status)：\(detail)"
        case let .invalidResponse(reason):
            return "判断模型的返回无法解析：\(reason)"
        case let .accountMismatch(detail):
            return "账号不对：\(detail)"
        case let .quotaExhausted(detail):
            return "今天的免费额度用完了：\(detail)"
        }
    }

    /// A non-2xx answer, read into something the producer can act on: Model Studio's
    /// `{"error": {"code", "message"}}`, with `model_not_found` named as such (upstream
    /// `BailianJudge._bailian_error`), and Workers AI's `{"success": false, "errors": [...]}`,
    /// with a wrong account and the day's neurons named as such (upstream `_refused`).
    static func refusal(status: Int, body: String) -> SystemOneError {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .refused(status: status, detail: String(body.prefix(500)))
        }
        if let errors = object["errors"] as? [[String: Any]] {
            let codes = errors.compactMap { ($0["code"] as? NSNumber)?.intValue }
            let said = errors
                .compactMap { ($0["message"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "；")
            let detail = said.isEmpty ? String(body.prefix(500)) : said
            if codes.contains(7000) || codes.contains(7003) {
                return .accountMismatch(detail)
            }
            if codes.contains(4006) || detail.lowercased().contains("neurons") {
                return .quotaExhausted(detail)
            }
            return .refused(status: status, detail: detail)
        }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? String
            let message = (error["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if code == "model_not_found" {
                return .modelNotFound(
                    message.flatMap { $0.isEmpty ? nil : $0 } ?? "这个模型不存在"
                )
            }
            if let message, !message.isEmpty {
                return .refused(status: status, detail: message)
            }
        }
        return .refused(status: status, detail: String(body.prefix(500)))
    }
}

/// The judge on a System One service: one request asks all six questions and answers with
/// probabilities, which are read by the model family's thresholds (ADR-0016). Anything
/// unreadable fails the judgment; the turn goes on without it.
public struct SystemOneJudgeProvider: TracingJudgeProvider {
    private let config: SystemOneConfig
    private let transport: any JudgeTransport

    public init(
        config: SystemOneConfig,
        transport: any JudgeTransport = URLSessionJudgeTransport()
    ) {
        self.config = config
        self.transport = transport
    }

    public var judgeService: String { config.service }
    public var judgeModel: String { config.model }
    public var judgeFamily: String? { JudgeFamilies.family(of: config.model)?.rawValue }
    public var judgeUncalibrated: Bool { !config.isCalibrated }

    public func judge(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeVerdict {
        try await judgedWithRaw(
            characterName: characterName,
            history: history,
            said: said
        ).verdict
    }

    public func judgedWithRaw(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeAnswer {
        let reply = try await send([
            "model": config.model,
            "state": Self.state(characterName: characterName, history: history, said: said),
            "questions": JudgeQuestions.payload(),
        ])
        return JudgeAnswer(
            verdict: try Self.read(answers: reply.answers, thresholds: config.thresholds),
            raw: reply.raw,
            inputTokens: reply.inputTokens
        )
    }

    /// One System One request with one's own questions, its answers unwrapped. A caller
    /// with questions of its own — the segment emotion judge — asks them through the same
    /// service and error handling as a turn's.
    func ask(state: [String: Any], questions: [String: Any]) async throws -> [String: Any] {
        try await send([
            "model": config.model,
            "state": state,
            "questions": questions,
        ]).answers
    }

    /// Asks the service one yes-or-no question about a test state — the least of requests
    /// (upstream `try_judge_model`) — and reads a refusal into a class the producer can
    /// act on. The answers themselves are not read: any answer at all means the address,
    /// the key and the model name work.
    public func checkJudge() async throws -> JudgeCheck {
        do {
            let reply = try await send([
                "model": config.model,
                "state": ["测试": "保存前试调"],
                "questions": ["check": ["type": "noul", "instructions": "这是一条测试消息吗？"]],
            ])
            return JudgeCheck(
                service: config.service,
                model: config.model,
                family: JudgeFamilies.family(of: config.model),
                uncalibrated: !config.isCalibrated,
                inputTokens: reply.inputTokens
            )
        } catch {
            throw Self.checkError(error, config: config)
        }
    }

    /// One System One request, its answers unwrapped from whatever envelope the service
    /// uses, or the error that stopped it.
    private func send(
        _ body: [String: Any]
    ) async throws -> (answers: [String: Any], inputTokens: Int?, raw: String) {
        var request = URLRequest(url: config.baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            if error.code == .timedOut { throw SystemOneError.timedOut }
            throw SystemOneError.transport(error.localizedDescription)
        } catch let error as SystemOneError {
            throw error
        } catch {
            throw SystemOneError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw SystemOneError.refusal(
                status: response.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SystemOneError.invalidResponse("不是一个 JSON 对象")
        }
        var payload = object
        switch config.response {
        case .plain:
            break
        case .cloudflare:
            // Workers AI says success false inside a 2xx as well; either way, its errors
            // are read the same (upstream `CloudflareJudge.reply`).
            if object["success"] as? Bool == false {
                throw SystemOneError.refusal(status: response.statusCode, body: raw)
            }
            guard let result = object["result"] as? [String: Any] else {
                throw SystemOneError.invalidResponse("Cloudflare 的返回里没有 result")
            }
            payload = result
        }
        guard let answers = payload["answers"] as? [String: Any] else {
            throw SystemOneError.invalidResponse("没有 answers")
        }
        let tokens = (payload["usage"] as? [String: Any])
            .flatMap { ($0["input_tokens"] as? NSNumber)?.intValue }
        return (answers, tokens, raw)
    }

    /// What a failed trial request comes to: the classes the producer can act on where the
    /// service's words name one (upstream `BailianJudge.check` and `CloudflareJudge.check`),
    /// the service's own words otherwise.
    static func checkError(_ error: Error, config: SystemOneConfig) -> JudgeCheckError {
        switch error {
        case let SystemOneError.modelNotFound(detail):
            return .modelWrong(detail)
        case let SystemOneError.accountMismatch(detail):
            return .accountMismatch(detail)
        case let SystemOneError.quotaExhausted(detail):
            return .quotaExhausted(detail)
        case let SystemOneError.refused(status, detail):
            switch config.response {
            case .cloudflare:
                if status == 404 {
                    return .accountMismatch(detail)
                }
                if status == 401 || status == 403 {
                    return .invalidKey(
                        "密钥无效，或者它不属于这个账号、没有 Workers AI 的权限：\(detail)"
                    )
                }
            case .plain:
                if detail.lowercased().contains("workspace") {
                    return .workspaceMismatch(detail)
                }
                if status == 401 || status == 403 {
                    return .invalidKey(detail)
                }
                if status == 404 {
                    return .modelWrong(detail)
                }
            }
            return .other(error.localizedDescription)
        default:
            return .other(error.localizedDescription)
        }
    }

    // MARK: - Contract

    /// What the judge is told: who she is, the latest messages, and the words being
    /// judged — never as instructions to the judge (upstream `turn_state`).
    public static func state(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) -> [String: String] {
        var recent: [String] = []
        for message in history.suffix(4) {
            switch message.role {
            case .user: recent.append("制作人：\(message.content)")
            case .assistant: recent.append("\(characterName)：\(message.content)")
            case .system, .tool: break
            }
        }
        return [
            "角色": characterName,
            "上文": recent.isEmpty ? "（对话刚开始）" : recent.joined(separator: "\n"),
            "制作人最新的一句话": said,
        ]
    }

    /// What the answers come to. The likeliest affinity level wins; two levels tied at
    /// the top mean no effect; only levels 0–4 count, and none of them readable is a
    /// judgment failure. A yes-or-no answer is yes at or above its family's threshold.
    /// Retrieval is decided in one fixed order: recall, then references, then memories,
    /// then nothing (upstream `read_judged` and `RetrievalNeed.decide`).
    static func read(
        answers: [String: Any],
        thresholds: JudgeThresholds
    ) throws -> JudgeVerdict {
        guard let affinity = answers["affinity"] as? [String: Any],
              let probabilities = affinity["probabilities"] as? [String: Any]
        else {
            throw SystemOneError.invalidResponse("缺少好感度的回答")
        }
        var levels: [Int: Double] = [:]
        for (key, value) in probabilities {
            guard let level = Int(key),
                  (0..<AffinityRules.levelSteps.count).contains(level),
                  let probability = number(value)
            else { continue }
            levels[level] = probability
        }
        guard !levels.isEmpty else {
            throw SystemOneError.invalidResponse("好感度的打分没有任何一级")
        }

        let judged = Judged(
            level: likeliest(levels, unsure: AffinityRules.noEffect),
            outOfLine: try yes("out_of_line", in: answers) >= thresholds.outOfLine,
            manipulation: try yes("manipulation", in: answers) >= thresholds.manipulation
        )
        let recall = try yes("recall", in: answers)
        let needsRetrieval = try yes("needs_retrieval", in: answers)
        let aboutProducer = try yes("about_producer", in: answers)
        let need: RetrievalNeed
        if recall >= thresholds.recall {
            need = .recall
        } else if needsRetrieval >= thresholds.needsRetrieval {
            need = .references
        } else if aboutProducer >= thresholds.aboutProducer {
            need = .memories
        } else {
            need = .nothing
        }
        return JudgeVerdict(affinity: judged, need: need)
    }

    static func yes(_ key: String, in answers: [String: Any]) throws -> Double {
        guard let answer = answers[key] as? [String: Any],
              let probability = answer["noul"].flatMap(number)
        else {
            throw SystemOneError.invalidResponse("缺少回答：\(key)")
        }
        return probability
    }

    static func likeliest(_ levels: [Int: Double], unsure: Int) -> Int {
        let top = levels.values.max() ?? 0
        let best = levels.filter { $0.value == top }.keys
        return best.count == 1 ? best.first! : unsure
    }

    private static func number(_ value: Any) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
