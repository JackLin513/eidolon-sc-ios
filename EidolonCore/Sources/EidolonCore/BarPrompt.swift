import Foundation

/// One message of a visit's prompt, and whether the service caches up to it (upstream
/// `ChatMessage` with its `cache_breakpoint`).
public struct BarChatMessage: Sendable, Hashable {
    public var role: String
    public var content: String
    public var cacheBreakpoint: Bool

    public init(role: String, content: String, cacheBreakpoint: Bool = false) {
        self.role = role
        self.content = content
        self.cacheBreakpoint = cacheBreakpoint
    }
}

/// The bar's prompt (upstream `bar_prompt.py`), the same four parts in every call of a visit
/// (ADR-0021, verbatim by ADR-0004):
///
/// 1. what she is and how a visit is written, marked for the service to cache: her sheet,
///    her birthday, the world setting, the IF the bar is in and what it keeps to, how a
///    visit goes and the output format;
/// 2. this visit, the same for each of its calls;
/// 3. what each call before asked for and what was written, the last marked for the
///    service to cache;
/// 4. what this call is to write.
public enum BarPrompt {
    /// What she remembers of her visits with the user done before this one.
    public struct Remembered: Sendable, Hashable {
        public var visits: Int
        public var lastLeftAt: Date?
        public var lastOrders: [Had]
        public var lastDrunk: Bool

        public init(visits: Int = 0, lastLeftAt: Date? = nil, lastOrders: [Had] = [], lastDrunk: Bool = false) {
            self.visits = visits
            self.lastLeftAt = lastLeftAt
            self.lastOrders = lastOrders
            self.lastDrunk = lastDrunk
        }
    }

    // MARK: - The first part

    /// The first part: what every user's visits with her open with that day.
    public static func shared(sheet: String, birthday: String, world: String?) -> String {
        var parts = [sheet]
        if !birthday.isEmpty { parts.append(birthday) }
        if let world, !world.isEmpty { parts.append(world) }
        return ([parts, [barIF, writing, format]].flatMap { $0 }).joined(separator: "\n\n")
    }

    // MARK: - The second part

    /// The second part: this visit, as it is at `now`, as she comes in, with those of her
    /// `facts` the topic found, best first.
    public static func visit(
        aboutProducer: String,
        reason: BarReason,
        topic: BarTopic,
        cups: Int,
        affinityLines: [String],
        today: [String],
        remembered: Remembered,
        now: Date,
        character: CharacterConfig,
        catalog: DrinkCatalog,
        facts: [String]
    ) throws -> String {
        let why = "你今晚来的缘由：\(reason.note)进门时的心情：\(reason.mood.zh)。"
        let lines = ["# 这次光顾", why, "闲聊的话题：\(topic.note)", "你今晚打算喝 \(cups) 杯，喝完就告别。"]
            + affinityLines + today
        var parts = [
            aboutProducer, lines.joined(separator: "\n"),
            try rememberedBlock(remembered, now: now, catalog: catalog),
            try tastes(character, catalog: catalog),
        ]
        if !facts.isEmpty { parts.append(factsBlock(facts)) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - The last part

    /// The last part of the first call: her coming in and ordering.
    public static func openingAsk(_ order: BarOrder) -> String {
        ["这次写：进门，然后点第一杯。\(chinese)", orderCard(order)].joined(separator: "\n\n")
    }

    /// The last part of a call after a drink is served her with the producer saying `enjoy`,
    /// another to come: her reaction, the talk and her next order.
    public static func servingAsk(_ serving: Serving, enjoy: String, _ order: BarOrder) -> String {
        [
            servedBlock(serving, enjoy: enjoy),
            "这次写：这杯的反应、闲聊，然后点下一杯。\(chinese)",
            orderCard(order),
        ].joined(separator: "\n\n")
    }

    /// The last part of the call after the last drink of `servings` is served her, the last
    /// she has, `drunk` or not: her reaction, a short talk and her farewell, drunk after her
    /// reaction if she is.
    public static func farewellAsk(
        _ serving: Serving, enjoy: String, servings: [Serving], drunk: Bool
    ) -> String {
        let each = servings.enumerated()
            .map { "第 \($0.offset + 1) 杯\($0.element.tier.zh)" }
            .joined(separator: "；")
        var parts = [
            servedBlock(serving, enjoy: enjoy),
            "这次写：这杯的反应、一小段闲聊，然后告别。不再点单。\(chinese)",
        ]
        if drunk {
            parts.append(
                "这杯的反应照常写；写完反应，从这一段起你醉了：闲聊和告别都是醉着的样子，"
                    + "话多、犯困、情绪起伏，会说说心里话。"
            )
        }
        parts.append("这次的每一杯：\(each)。你今晚\(drunk ? "喝醉了" : "没有喝醉")。")
        return parts.joined(separator: "\n\n")
    }

    /// What she is to order, and how: never what else would be right for it.
    public static func orderCard(_ order: BarOrder) -> String {
        let drink = order.target
        var card = [
            "点单卡：",
            "- 说法：\(phrasings[order.phrasing]!)",
            "- 饮品：\(drink.name)（日文名 \(drink.nameJa)），\(described(drink))。",
        ]
        if order.phrasing == .analogy { card.append("- 描述：\(drink.description)") }
        if order.phrasing.names {
            card.append("- 名字：要说出来，日语台词里说「\(drink.nameJa)」，中文字幕里写「\(drink.name)」。")
        } else {
            card.append("- 名字：不能说出来。日语台词和中文字幕里都不要出现任何饮品的名字。")
        }
        let words = order.words().joined(separator: "、")
        card.append("- 要提的条件：\(words.isEmpty ? "没有" : words)。")
        return card.joined(separator: "\n")
    }

    /// `ask` again, but for her order alone, which named drinks where it should not, or not
    /// the one it should, after the lines `before` it, which stand.
    public static func rewriteAsk(_ ask: String, _ order: BarOrder, before: [BarLine]) -> String {
        let drink = order.target
        let naming = order.phrasing.names
            ? "一定要说出名字：日语台词里说「\(drink.nameJa)」，中文字幕里写「\(drink.name)」。"
            : "不要提任何饮品的名字，日语台词和中文字幕里都不行。"
        let written = before.map { $0.written() }.joined(separator: "\n")
        return ([ask]
            + (before.isEmpty ? [] : ["这次前面已经写好了这些，不用再写：\n\(written)"])
            + ["你接着写的点单那一两句不合要求。这次只重写点单的那一两句，标上 order=\"true\"，别的都不写。" + naming]
        ).joined(separator: "\n\n")
    }

    // MARK: - The prompt

    /// The prompt of a call of a visit, after the calls `written`, each with what it asked
    /// for and what came of it.
    public static func prompt(
        shared: String, visit: String, written: [(ask: String, lines: [BarLine])], ask: String
    ) -> [BarChatMessage] {
        var messages = [
            BarChatMessage(role: "system", content: shared, cacheBreakpoint: true),
            BarChatMessage(role: "system", content: visit),
        ]
        for call in written {
            messages.append(BarChatMessage(role: "user", content: call.ask))
            messages.append(BarChatMessage(
                role: "assistant", content: call.lines.map { $0.written() }.joined(separator: "\n")
            ))
        }
        if !written.isEmpty {
            // What the next call opens with too, for a service to cache.
            let last = messages.count - 1
            messages[last] = BarChatMessage(
                role: messages[last].role, content: messages[last].content, cacheBreakpoint: true
            )
        }
        messages.append(BarChatMessage(role: "user", content: ask))
        return messages
    }

    // MARK: - Text

    /// The Chinese of the last part's instruction.
    static let chinese = "制作人的台词只写中文。"

    /// How she says her order, for the order card.
    static let phrasings: [Phrasing: String] = [
        .name: "直接说出饮品的名字。",
        .nameBig: "直接说出饮品的名字，并说要大杯。",
        .flavor: "只说想要什么口味的，不说是哪一款。",
        .kind: "只说想要哪一类的，可以绕着说（比如想要「烈一点的」就是男性化），不说是哪一款。",
        .conditions: "把下面这几个条件一起说出来，不说是哪一款。",
        .analogy: (
            "照这款饮品的描述，用你自己的话打个比方，让制作人猜是哪一款；不要照抄描述。"
                + "比方整个写在标 order=\"true\" 的那一两句里，不拆到铺垫里。"
        ),
        .myFavorite: "让制作人上一杯你喜欢的，不说是哪一款，看制作人记不记得你的口味。",
        .yourCall: "让制作人帮你拿主意，不说想要什么。",
        .usual: "说要「老样子」，也就是上次来时喝的那款，不说是哪一款。",
    ]

    static let barIF = #"""
                # 这里是 VA-283
                这是一个 IF 的故事：所有人都已经到了能喝酒的年纪；除此之外你还是你，仍是 283 事务所的偶像，制作人仍是你的制作人。制作人下班以后在一家叫「VA-283」的小酒吧当酒保，你今晚来店里光顾，就是来找制作人的。
                - 不提你或别人的具体年龄，也不讨论「其实还没成年」之类的话；不解释制作人为什么在这里当酒保。
                - 喝醉了也只是话多、犯困、情绪起伏、说说心里话，不往暧昧和色情的方向走。人设里不该说的话照旧不说。
                - 你不知道你们在别处聊过什么；这里只有今晚店里的事，和你记得的以前来店里的事。
                """#

    static let writing = #"""
                # 一次光顾怎么写
                你来写你和制作人的台词，制作人是酒保。每次只写最后一条消息要你写的那几段，写完就停，等制作人下一步。
                - 进门：5 到 7 句。按你来过几次打招呼，用来意定下心情，来意可以先只露一半；今天是你自己或组合伙伴的生日的话，在这里提一句；别人的生日和节日不用特意提，制作人说起再接。
                - 点单：先铺垫 1 到 2 句，然后照点单卡说出你要什么。说出点单的那一两句标上 order="true"，放在这次输出的最后；要什么只在这一两句里说：铺垫只说想来一杯、说说心情，不先说这一杯想要什么样的。点单卡上的条件一个不漏，没有的一个不加：卡上没写的，就不说加冰、大杯、什么口味或不要酒精（打比方照描述说，不算加条件）。
                - 上酒后的反应：2 到 4 句，照给你的判定写；上得对不对由判定说了算，不要自己判断。上错了抱怨几句就照常往下聊，不要求重做。
                - 闲聊：8 到 12 句，围着话题聊，来意也往深里说一点；最后一杯后的闲聊短一些，4 到 6 句。
                - 告别：2 到 4 句，收住来意，心情比进门时有了变化，用一句话带出这次喝得怎么样，可以说下次再来。
                - 句数是你和制作人合计的。制作人是在和你聊天：进门、反应和告别里都有他一两句；闲聊里你们一来一回，他接话、追问、说说自己的看法和今天的小事，占三到四成，不要连着好几句都是你在说。他不替你挑饮品、不提议你点什么，只说中文。
                - 不写选项，不替制作人做决定，也不写制作人调酒、上酒：那由制作人自己来。
                - 今天、今晚的小事和心情可以即兴；过去的经历，家人、组合伙伴和别的偶像的名字、关系和设定，只用人设和「角色资料」里有的，没有的就说得笼统些，不编具体的名字和事件。
                """#

    static let format = #"""
                # 输出格式
                每句台词一组。你的台词用日语，后面附中文字幕，并标上说这句时的表情；制作人的台词只写中文：
                <her emotion="happy"><ja>日语台词</ja><zh>中文字幕</zh></her>
                <producer>制作人的台词</producer>
                <her emotion="calm" order="true"><ja>点单的那句</ja><zh>它的中文字幕</zh></her>
                - 表情只能是 calm、happy、shy、surprised、sad、angry、thinking 之一。
                - 中文字幕照日语台词完整译出，不增不减；日语台词里不夹英文。
                - 饮品的名字在日语台词里用日文名，在中文字幕里用英文原名，不要翻译。
                - 制作人的台词只用中文写，前面都是日语也一样；不写日语，不套 <ja>、<zh>，不加引号。
                - 除了这些标签和标签里的内容，不要输出任何其他文字，也不要写动作和旁白。
                """#

    // MARK: - Private

    private static func described(_ drink: Drink) -> String {
        "口味\(drink.flavor.zh)，种类\(drink.kind.zh)"
    }

    private static func servedBlock(_ serving: Serving, enjoy: String) -> String {
        let served = serving.served
        var lines = [
            "制作人给你上了一杯 \(glass(served))，说：「\(enjoy)」",
            "判定：\(serving.tier.zh)。",
        ]
        if let wrong = serving.wrong {
            lines.append(wrongLine(wrong, served))
        } else if served.drink.id != serving.order.target.id {
            lines.append("这杯不是点单卡上那款，但也合你的意：不要说这杯和你想的不一样。")
        }
        return lines.joined(separator: "\n")
    }

    private static func glass(_ served: Served) -> String {
        let drink = served.drink
        let alcohol = served.alcoholic ? "含酒精" : "不含酒精"
        let big = served.big ? "，大杯" : ""
        return "\(drink.name)（\(described(drink))\(big)，\(alcohol)）"
    }

    private static let wrongs: [Wrong: String] = [
        .notUsual: "错在哪：你要的是老样子，这杯不是上次那款。",
        .flavorOnly: "错在哪：口味对了，种类不对。",
        .kindOnly: "错在哪：种类对了，口味不对。",
        .off: "错在哪：不是你要的，完全不对。",
    ]

    private static func wrongLine(_ wrong: Wrong, _ served: Served) -> String {
        if wrong == .disliked {
            return "错在哪：这是你讨厌的\(served.drink.flavor.zh)口味。要写成明显的不喜欢，但不赶人、不翻脸。"
        }
        if wrong == .alcohol {
            return "错在哪：你说了不要酒精，这杯却有酒。要写成明显的不喜欢，但不赶人、不翻脸。"
        }
        return wrongs[wrong]!
    }

    private static func rememberedBlock(_ remembered: Remembered, now: Date, catalog: DrinkCatalog) throws -> String {
        var lines = ["# 你在 VA-283 的记录"]
        guard remembered.visits != 0, let last = remembered.lastLeftAt else {
            lines.append("这是你第一次来 VA-283。")
            return lines.joined(separator: "\n")
        }
        if remembered.visits >= BarRules.regularVisits {
            lines.append("你是这里的常客，已经来过 \(remembered.visits) 次了。")
        } else {
            lines.append("你来过 \(remembered.visits) 次了。")
        }
        let calendar = BarDates.beijing
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)
        ).day ?? 0
        lines.append(ago(days))
        if now.timeIntervalSince(last) > BarRules.longAgo {
            lines.append("很久没来了，进门时可以提一句好久不见。")
        }
        let each = remembered.lastOrders.enumerated().map { index, had in
            "第 \(index + 1) 杯要的是 \(name(had.target, catalog))，制作人上的是 "
                + "\(name(had.served, catalog))\(had.big ? "（大杯）" : "")，\(had.tier.zh)"
        }
        lines.append("上次点的：\(each.joined(separator: "；"))。")
        lines.append(
            remembered.lastDrunk
                ? "上次喝醉了，可以提一句，但不会因此只点不含酒精的。" : "上次没有喝醉。"
        )
        lines.append("聊过什么你不记得了。")
        return lines.joined(separator: "\n")
    }

    /// A drink's name, or its identifier if the catalog no longer has it.
    private static func name(_ id: String, _ catalog: DrinkCatalog) -> String {
        catalog.drink(id: id)?.name ?? id
    }

    private static func ago(_ days: Int) -> String {
        if days < 2 { return "上次来是\(days == 0 ? "今天早些时候" : "昨天")。" }
        return "上次来是 \(days) 天前。"
    }

    private static func tastes(_ character: CharacterConfig, catalog: DrinkCatalog) throws -> String {
        guard let bar = character.bar else {
            throw EidolonError.invalidContent("角色 \(character.id) 没有配酒吧的口味")
        }
        var lines = ["# 你在酒吧的口味"]
        lines.append("喜欢的口味：\(bar.flavors.map(\.zh).joined(separator: "、"))。")
        if let kind = bar.kindValue { lines.append("喜欢的种类：\(kind.zh)。") }
        let favorites = bar.favorites.compactMap { catalog.drink(id: $0)?.name }.joined(separator: "、")
        lines.append("爱喝的：\(favorites)。")
        if let disliked = bar.dislikedValue { lines.append("讨厌的口味：\(disliked.zh)。") }
        if let tolerance = bar.tolerance { lines.append("酒量：\(tolerance.zh)。") }
        lines.append(
            "这些可以在闲聊里偶尔自然地带出一点，让制作人慢慢摸清；不要一口气说出来，闲聊里也不要用"
                + "「\(DrinkKind.girly.zh)」「\(DrinkKind.promo.zh)」这类菜单上的分类词说自己的口味。"
        )
        return lines.joined(separator: "\n")
    }

    private static func factsBlock(_ facts: [String]) -> String {
        var lines = [
            "# 角色资料",
            "「角色资料」是关于你自己和身边人物的设定。下面几条和这次的话题可能有关，聊到时照这些说，用不上的可以不提。",
        ]
        for fact in facts { lines += ["", fact] }
        return lines.joined(separator: "\n")
    }
}

/// Days, as the bar's records and prompts reckon them: the device's day for the bar (ADR-0021),
/// Beijing's only for the one prompt line that still counts days upstream's way.
public enum BarDates {
    /// Beijing's calendar, kept for the one place the prompt still counts days upstream's way
    /// (`_remembered`'s 「多久没来」, ADR-0021). The bar's own days are the device's.
    public static var beijing: Calendar { calendar(in: TimeZone(identifier: "Asia/Shanghai") ?? .current) }

    public static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The day at `now` in `timeZone`, as the bar's records key it: the device's day on the
    /// phone (ADR-0021), not the server's (upstream `affinity.day_of` uses Beijing's).
    public static func day(of now: Date, in timeZone: TimeZone = .current) -> String {
        let parts = calendar(in: timeZone).dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
