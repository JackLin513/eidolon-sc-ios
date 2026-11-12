import Foundation

/// The franchise-specific names and scene text that used to be hardcoded in the judge,
/// memory, title and producer prompts. A content bundle may carry one; the built-in
/// value keeps the existing SC behaviour for older bundles.
public struct FranchisePrompt: Codable, Sendable, Hashable {
    public var workName: String
    public var organization: String
    public var producerRole: String
    public var language: String
    public var judgeScene: String
    public var callScene: String
    public var producerLine: String
    public var memoryInstructions: String
    public var titleInstructions: String
    /// The NovelAI series tag for photos; nil keeps the SC tag for older packs.
    public var photoSeries: String?

    enum CodingKeys: String, CodingKey {
        case workName = "work_name"
        case organization
        case producerRole = "producer_role"
        case language
        case judgeScene = "judge_scene"
        case callScene = "call_scene"
        case producerLine = "producer_line"
        case memoryInstructions = "memory_instructions"
        case titleInstructions = "title_instructions"
    }

    public init(
        workName: String,
        organization: String,
        producerRole: String = "制作人",
        language: String = "ja",
        judgeScene: String,
        callScene: String,
        producerLine: String,
        memoryInstructions: String,
        titleInstructions: String,
        photoSeries: String? = nil
    ) {
        self.workName = workName
        self.organization = organization
        self.producerRole = producerRole
        self.language = language
        self.judgeScene = judgeScene
        self.callScene = callScene
        self.producerLine = producerLine
        self.memoryInstructions = memoryInstructions
        self.titleInstructions = titleInstructions
        self.photoSeries = photoSeries
    }

    /// The built-in SC identity, copied verbatim from the pre-pack prompts.
    public static let shiny = FranchisePrompt(
        workName: "偶像大师 闪耀色彩",
        organization: "283 事务所",
        producerRole: "制作人",
        language: "ja",
        judgeScene: "角色扮演对话中，角色是《偶像大师 闪耀色彩》283 事务所的偶像（或事务员），正在和制作人对话。",
        callScene: "角色扮演的通话中，角色是《偶像大师 闪耀色彩》283 事务所的偶像（或事务员），正在和制作人通话。",
        producerLine: "和你对话的是你的制作人，也就是 283 事务所的制作人。",
        memoryInstructions: "你负责替《偶像大师 闪耀色彩》283 事务所的偶像们（还有事务员）记住关于制作人的事。制作人就是正在和她们对话的用户。",
        titleInstructions: "你负责给制作人和一位角色（283 事务所的偶像或事务员）的一段对话起标题，好让制作人以后在历史对话里一眼认出这段聊了什么。制作人就是正在和她对话的用户。",
        photoSeries: "idolmaster shiny colors"
    )

    public static let totsulover = FranchisePrompt(
        workName: "ディメンション凸ラバース！！",
        organization: "学园",
        producerRole: "制作人",
        language: "ja",
        judgeScene: "角色扮演对话中，角色是《ディメンション凸ラバース！！》中学园的一员，正在和制作人对话。",
        callScene: "角色扮演的通话中，角色是《ディメンション凸ラバース！！》中学园的一员，正在和制作人通话。",
        producerLine: "和你对话的是你的制作人，也是学园相关的人。",
        memoryInstructions: "你负责替《ディメンション凸ラバース！！》中学园的角色们记住关于制作人的事。制作人就是正在和她们对话的用户。",
        titleInstructions: "你负责给制作人和一位角色（《ディメンション凸ラバース！！》中学园的一员）的一段对话起标题，好让制作人以后在历史对话里一眼认出这段聊了什么。制作人就是正在和她对话的用户。",
        photoSeries: ""
    )

    public static func load(in contentDirectory: URL) -> FranchisePrompt? {
        let url = contentDirectory.appendingPathComponent("characters/franchise.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FranchisePrompt.self, from: data)
    }
}

/// The active prompt pack. Content activation sets it; tests and older bundles keep the
/// built-in SC text. The value is read on prompt-building paths, not UI state.
public enum FranchisePromptContext {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = FranchisePrompt.shiny

    public static var current: FranchisePrompt {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
