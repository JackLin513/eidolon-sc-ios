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
    public var outOfLine: Double
    public var manipulation: Double

    public init(
        needsRetrieval: Double,
        recall: Double,
        aboutProducer: Double,
        outOfLine: Double,
        manipulation: Double
    ) {
        self.needsRetrieval = needsRetrieval
        self.recall = recall
        self.aboutProducer = aboutProducer
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
                outOfLine: 0.7, manipulation: 0.4
            )
        case .clef:
            return JudgeThresholds(
                needsRetrieval: 0.5, recall: 0.8, aboutProducer: 0.1,
                outOfLine: 0.5, manipulation: 0.5
            )
        case .clefFlash:
            return JudgeThresholds(
                needsRetrieval: 0.5, recall: 0.7, aboutProducer: 0.3,
                outOfLine: 0.6, manipulation: 0.6
            )
        case .decisionModel:
            return JudgeThresholds(
                needsRetrieval: 0.06, recall: 0.8, aboutProducer: 0.1,
                outOfLine: 0.3, manipulation: 0.4
            )
        }
    }

    /// The thresholds `model` judges by; Jev's for a model not known.
    public static func thresholds(for model: String) -> JudgeThresholds {
        thresholds(of: family(of: model) ?? fallback)
    }
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

    public init(
        baseURL: URL,
        model: String,
        apiKey: String,
        service: String = "阿里云百炼",
        timeout: TimeInterval = 5
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.service = service
        self.timeout = timeout
    }

    public var thresholds: JudgeThresholds {
        JudgeFamilies.thresholds(for: model)
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

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "判断服务超时"
        case let .transport(detail):
            return "无法连接判断服务：\(detail)"
        case let .modelNotFound(detail):
            return "百炼没有这个模型：\(detail)"
        case let .refused(status, detail):
            return "判断服务返回 \(status)：\(detail)"
        case let .invalidResponse(reason):
            return "判断模型的返回无法解析：\(reason)"
        }
    }

    /// A non-2xx answer: Model Studio's `{"error": {"code", "message"}}` read into
    /// something the producer can act on, with `model_not_found` named as such (upstream
    /// `BailianJudge._bailian_error`).
    static func refusal(status: Int, body: String) -> SystemOneError {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any]
        {
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
        let body: [String: Any] = [
            "model": config.model,
            "state": Self.state(characterName: characterName, history: history, said: said),
            "questions": JudgeQuestions.payload(),
        ]
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
        guard let answers = object["answers"] as? [String: Any] else {
            throw SystemOneError.invalidResponse("没有 answers")
        }
        let tokens = (object["usage"] as? [String: Any])
            .flatMap { ($0["input_tokens"] as? NSNumber)?.intValue }
        return JudgeAnswer(
            verdict: try Self.read(answers: answers, thresholds: config.thresholds),
            raw: raw,
            inputTokens: tokens
        )
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
