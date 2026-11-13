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

    /// How this work addresses the user in third person. Nil keeps "制作人" and the
    /// original SC prompts.
    public var protagonistTerm: String?
    /// A complete replacement for the per-turn user/producer system message. Nil keeps
    /// the existing `ProducerProfile.prompt` (SC and older packs).
    public var userSection: String?
    /// Appended only while adult mode is off. Nil keeps the boundary in the sheet (SC).
    public var adultBoundary: String?
    /// A complete replacement for `WorldSetting.prompt`. Nil keeps the structured world.
    public var worldPrompt: String?
    /// Word-level replacements applied to every prompt this franchise builds, longest
    /// source string first. Nil keeps the SC vocabulary byte for byte.
    public var vocabulary: [String: String]?

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
        case photoSeries = "photo_series"
        case protagonistTerm = "protagonist_term"
        case userSection = "user_section"
        case adultBoundary = "adult_boundary"
        case worldPrompt = "world_prompt"
        case vocabulary
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
        photoSeries: String? = nil,
        protagonistTerm: String? = nil,
        userSection: String? = nil,
        adultBoundary: String? = nil,
        worldPrompt: String? = nil,
        vocabulary: [String: String]? = nil
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
        self.protagonistTerm = protagonistTerm
        self.userSection = userSection
        self.adultBoundary = adultBoundary
        self.worldPrompt = worldPrompt
        self.vocabulary = vocabulary
    }

    /// The SC prompts as they were before content packs existed. Every optional
    /// override is nil, so `localized` is a no-op and the upstream goldens stay exact.
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

    /// The built-in Dimension Lover identity, kept in sync with the package writer in
    /// `tools/import_totsulover_story.py`. A package carries the long-form versions.
    public static let totsulover = FranchisePrompt(
        workName: "ディメンション凸ラバース！！",
        organization: "学园",
        producerRole: "主人公",
        language: "ja",
        judgeScene: "角色扮演对话中，角色是《ディメンション凸ラバース！！》中学园的一员，正在和崩月槐对话。",
        callScene: "角色扮演的通话中，角色是《ディメンション凸ラバース！！》中学园的一员，正在和崩月槐通话。",
        producerLine: "正在和你对话的是崩月槐。请按原作中你与他的关系称呼他。",
        memoryInstructions: "你负责替《ディメンション凸ラバース！！》中学园的角色们记住关于崩月槐的事。崩月槐就是正在和她们对话的用户。",
        titleInstructions: "你负责给崩月槐和一位角色（《ディメンション凸ラバース！！》中学园的一员）的一段对话起标题，好让崩月槐以后在历史对话里一眼认出这段聊了什么。崩月槐就是正在和她对话的用户。",
        photoSeries: "",
        protagonistTerm: "槐",
        userSection: """
            # 和你对话的人
            正在和你对话的是崩月槐（くずつき かい），男性，崩月家的魔术师，也是转入「学园」的转学生。
            请按你在原作中对他的称呼叫他：
            - 夜乃桜、ソフィア・ランカスター：「槐くん」
            - 海漫華淡：「槐さん」
            - 崩月水仙：「槐お兄ちゃん」
            不要用身份标签或泛称代替这些称呼，也不要给他套用其他作品的职业称呼。
            """,
        adultBoundary: """
            # 亲密边界
            不要进入成人亲密、婚姻承诺、强烈占有、病态依赖、控制欲或现实接触幻想。
            """,
        worldPrompt: """
            # 世界设定
            《ディメンション凸ラバース！！》的舞台是横滨的「学园」。学园既是学校，也是对抗怪兽的组织；学生会是学生一侧的核心。
            - 学园：以学生会为核心，夜乃桜担任学生会长，海漫華淡与ソフィア・ランカスター也在学生会。
            - 魔术师：研究反现实与魔术的势力，崩月家所属。
            - 崩月家：研究反现实与魔术的家族，崩月槐与妹妹崩月水仙出身于此。
            主要人物：夜乃桜、海漫華淡、ソフィア・ランカスター、崩月水仙；崩月槐是本校学生，也是故事的中心人物。
            """,
        vocabulary: ["283 事务所": "学园", "制作人": "槐", "偶像": "角色", "事务所": "学园"]
    )

    /// Applies this franchise's vocabulary to text built by shared prompt modules.
    /// The SC built-in has no vocabulary, so its prompts are byte-identical.
    public func localized(_ text: String) -> String {
        guard let vocabulary, !vocabulary.isEmpty else { return text }
        var result = text
        for key in vocabulary.keys.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: key, with: vocabulary[key] ?? key)
        }
        return result
    }

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

    /// Localizes a prompt fragment for the active franchise.
    public static func localize(_ text: String) -> String {
        current.localized(text)
    }
}
