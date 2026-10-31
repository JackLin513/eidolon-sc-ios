import Foundation

/// One source of a guide sentence: a small link at its end (spec #53).
public struct CycleGuideSource: Sendable, Hashable {
    public var label: String
    public var href: String

    public init(label: String, href: String) {
        self.label = label
        self.href = href
    }
}

public struct CycleGuideSentence: Sendable, Hashable {
    public var text: String
    public var sources: [CycleGuideSource]

    public init(text: String, sources: [CycleGuideSource]) {
        self.text = text
        self.sources = sources
    }
}

public struct CycleGuidePart: Sendable, Hashable {
    public var heading: String?
    public var sentences: [CycleGuideSentence]

    public init(heading: String? = nil, sentences: [CycleGuideSentence]) {
        self.heading = heading
        self.sentences = sentences
    }
}

public struct CycleGuideBlock: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var lead: String
    public var parts: [CycleGuidePart]
    public var hasDiagram: Bool

    public init(
        id: String, title: String, lead: String, parts: [CycleGuidePart],
        hasDiagram: Bool = false
    ) {
        self.id = id
        self.title = title
        self.lead = lead
        self.parts = parts
        self.hasDiagram = hasDiagram
    }
}

public enum CycleDiagramKind: Sendable, Hashable {
    case period
    case fertile
    case ovulation
}

/// One day of the 28-day example diagram.
public struct CycleDiagramDay: Sendable, Hashable {
    public var day: Int
    public var kind: CycleDiagramKind?

    public init(day: Int, kind: CycleDiagramKind?) {
        self.day = day
        self.kind = kind
    }
}

/// The cycle page's seven guide blocks and the 28-day diagram, ported verbatim from the
/// upstream `cycleGuide.ts`; general health information, never a diagnosis of her.
public enum CycleGuide {
    public static let irregularBlockID = "puberty"

    static let msd = "https://www.msdmanuals.cn/home/women-s-health-issues"
    static let msdPro = "https://www.msdmanuals.cn/professional/gynecology-and-obstetrics"
    static let msdBleeding = "\(msd)/menstrual-disorders-and-abnormal-uterine-bleeding"

    static let nhsFertility = CycleGuideSource(
        label: "NHS",
        href: "https://www.nhs.uk/conditions/periods/fertility-in-the-menstrual-cycle/"
    )
    static let nhsPeriods = CycleGuideSource(
        label: "NHS", href: "https://www.nhs.uk/conditions/periods/"
    )
    static let msdCycle = CycleGuideSource(
        label: "默沙东",
        href: "\(msd)/biology-of-the-female-reproductive-system/menstrual-cycle"
    )
    static let msdEndocrinology = CycleGuideSource(
        label: "默沙东专业版",
        href: "\(msdPro)/female-reproductive-endocrinology/female-reproductive-endocrinology"
    )
    static let msdFertilityAwareness = CycleGuideSource(
        label: "默沙东专业版",
        href: "\(msdPro)/family-planning/fertility-awareness-based-methods-of-contraception"
    )
    static let msdPuberty = CycleGuideSource(
        label: "默沙东",
        href: "\(msd)/biology-of-the-female-reproductive-system/puberty-in-girls"
    )
    static let msdPms = CycleGuideSource(
        label: "默沙东", href: "\(msdBleeding)/premenstrual-syndrome-pms"
    )
    static let msdCramps = CycleGuideSource(
        label: "默沙东", href: "\(msdBleeding)/menstrual-cramps"
    )
    static let msdAbsent = CycleGuideSource(
        label: "默沙东", href: "\(msdBleeding)/absence-of-menstrual-periods"
    )
    static let msdAub = CycleGuideSource(
        label: "默沙东", href: "\(msdBleeding)/abnormal-uterine-bleeding-aub"
    )
    static let msdVaginalBleeding = CycleGuideSource(
        label: "默沙东", href: "\(msd)/symptoms-of-gynecologic-disorders/vaginal-bleeding"
    )
    static let msdPelvicPain = CycleGuideSource(
        label: "默沙东", href: "\(msd)/symptoms-of-gynecologic-disorders/pelvic-pain-in-women"
    )
    static let msdPcos = CycleGuideSource(
        label: "默沙东",
        href: "\(msdBleeding)/polyendocrine-metabolic-ovarian-syndrome-pmos"
    )
    static let msdEndometriosis = CycleGuideSource(
        label: "默沙东", href: "\(msd)/endometriosis/endometriosis"
    )
    static let msdFibroids = CycleGuideSource(
        label: "默沙东", href: "\(msd)/fibroids/uterine-fibroids"
    )
    static let msdOvarianCysts = CycleGuideSource(
        label: "默沙东",
        href: "\(msd)/miscellaneous-gynecologic-abnormalities/ovarian-cysts-and-other-benign-ovarian-masses"
    )
    static let msdTorsion = CycleGuideSource(
        label: "默沙东",
        href: "\(msd)/miscellaneous-gynecologic-abnormalities/adnexal-torsion"
    )
    static let laplacePredictions = CycleGuideSource(
        label: "LAPLACE Cycles", href: "https://laplace.live/cycles/predictions?locale=en"
    )
    static let laplace = CycleGuideSource(
        label: "LAPLACE Cycles", href: "https://laplace.live/cycles"
    )
    static let laplaceOvu = CycleGuideSource(
        label: "LAPLACE", href: "https://laplace.live/ovu"
    )
    static let chinaAub = CycleGuideSource(
        label: "中国指南",
        href: "https://drugs.dxy.cn/pc/clinicalDecision/pdVhB3viFNd_kqK1A_KHR4g"
    )
    static let adolescentAub = CycleGuideSource(
        label: "中国青春期共识", href: "https://gocm.bmj.com/content/5/1/e000115"
    )
    static let acog = CycleGuideSource(
        label: "ACOG",
        href: "https://www.acog.org/clinical/guidance/committee-opinion/2015/12/menstruation-in-girls-and-adolescents-using-the-menstrual-cycle-as-a-vital-sign"
    )
    static let cmaPuberty = CycleGuideSource(
        label: "中华医学会", href: "https://www.cma.org.cn/art/2022/7/30/art_4584_46755.html"
    )
    static let cmaPremenstrual = CycleGuideSource(
        label: "中华医学会", href: "https://www.cma.org.cn/art/2022/12/19/art_4584_48741.html"
    )
    static let shaw = CycleGuideSource(
        label: "Shaw 综述", href: "https://pmc.ncbi.nlm.nih.gov/articles/PMC6570576/"
    )
    static let ma2023 = CycleGuideSource(
        label: "Ma 2023", href: "https://doi.org/10.1007/s12519-023-00723-9"
    )
    static let bull2019 = CycleGuideSource(
        label: "Bull 2019", href: "https://www.nature.com/articles/s41746-019-0152-7"
    )
    static let fehring2006 = CycleGuideSource(
        label: "Fehring 2006", href: "https://epublications.marquette.edu/nursing_fac/11/"
    )
    static let wilcox2000 = CycleGuideSource(
        label: "Wilcox 2000", href: "https://pmc.ncbi.nlm.nih.gov/articles/PMC27529/"
    )
    static let johnson2018 = CycleGuideSource(
        label: "Johnson 2018",
        href: "https://www.tandfonline.com/doi/full/10.1080/03007995.2018.1475348"
    )
    static let yang2006 = CycleGuideSource(
        label: "Yang 2006", href: "https://doi.org/10.1007/s12110-006-1005-z"
    )
    static let who = CycleGuideSource(
        label: "WHO",
        href: "https://www.fphandbook.org/sites/default/files/JHU%20HBk22%20-%20Chapter%2018.pdf"
    )
    static let gdCdc = CycleGuideSource(
        label: "广东省疾控", href: "https://cdcp.gd.gov.cn/zzzq/jkts/content/post_4779475.html"
    )

    static func sentence(_ text: String, _ sources: CycleGuideSource...) -> CycleGuideSentence {
        CycleGuideSentence(text: text, sources: sources)
    }

    static func line(_ text: String, _ sources: CycleGuideSource...) -> CycleGuidePart {
        CycleGuidePart(sentences: [CycleGuideSentence(text: text, sources: sources)])
    }

    static func headed(
        _ heading: String, _ sentences: CycleGuideSentence...
    ) -> CycleGuidePart {
        CycleGuidePart(heading: heading, sentences: sentences)
    }

    /// The 28-day example: the period on days 1–5, ovulation on day 15, fertile days 10–16.
    public static func diagramDays() -> [CycleDiagramDay] {
        let cycle = 28
        let period = 5
        let beforeNext = 14
        let fertileBefore = 5
        let fertileAfter = 1
        let ovulation = cycle + 1 - beforeNext
        return (1...cycle).map { day in
            if day <= period { return CycleDiagramDay(day: day, kind: .period) }
            if day == ovulation { return CycleDiagramDay(day: day, kind: .ovulation) }
            if day >= ovulation - fertileBefore, day <= ovulation + fertileAfter {
                return CycleDiagramDay(day: day, kind: .fertile)
            }
            return CycleDiagramDay(day: day, kind: nil)
        }
    }

    public static let blocks: [CycleGuideBlock] = [
        howBlock,
        basicsBlock,
        pubertyBlock,
        premenstrualBlock,
        healthBlock,
        careBlock,
        mythsBlock,
    ]

    private static let howBlock = CycleGuideBlock(
        id: "how",
        title: "怎么算的",
        lead: "推算只看记下的日期，按下面几步算。它能估出大概哪天，不能知道她身体里发生了什么。",
        parts: [
            line(
                "一个周期从经期第一天算起，到下次经期第一天的前一天为止。",
                nhsFertility, msdCycle
            ),
            line(
                "只记了一次时，周期按 28 天、经期按 5 天粗略估计：28 天接近人群周期长度的中位数，5 天是常见的经期天数。",
                laplacePredictions, nhsPeriods
            ),
            line(
                "记满两次后，取最近至多 8 个周期长度的中位数。用中位数，是为了不被一次特别长或特别短的周期带偏。",
                laplacePredictions
            ),
            line(
                "短于 15 天、长于 60 天的间隔先去掉；长到剩下最短那个的 1.6 倍以上的，当作中间漏记了一次，也不算进去，因为一段很长的空档不能说明中间没来过。",
                laplacePredictions
            ),
            line("经期天数取最近 6 次的中位数。", laplacePredictions),
            line(
                "下次经期第一天是最后一次记下的第一天加上推算的周期，之后每隔一个周期推一次，共 3 次。",
                laplacePredictions
            ),
            line(
                "周期页把每次推算的经期之前 5 天标作经前，这是我们的设定，依据是默沙东写经前不适多在经期前 5 天到几小时出现。",
                msdPms
            ),
            line(
                "这几种情况下推算变淡、只作参考：只记了一次；最长和最短的周期差 7 天以上（中国指南也以 7 天为「规律」的界线）；有疑似漏记的间隔被去掉；到了推算的日子还没记下新的一次。",
                laplacePredictions, chinaAub
            ),
            line(
                "「过去的估算平均差」：对每个已经结束的周期，只用它开始之前的记录重算一遍当时的推算，看实际早了或晚了几天，再取平均。",
                laplacePredictions
            ),
            line(
                "示意图以 28 天为例：下次经期第一天是第 29 天，往前数 14 天，排卵日落在第 15 天；易孕期从排卵日前 5 天到后 1 天，即第 10–16 天。",
                msdFertilityAwareness, msdCycle
            ),
            line(
                "「往前数 14 天」只是近似：排卵到下次经期（黄体期）实测平均约 12.4 天，人和人之间差约 2 天；28 天的周期里，正好在下次经期前 14 天排卵的只有约一成。所以示意图上的排卵日和易孕期只是讲道理用的例子，周期页也不为任何一位推算它们。",
                bull2019, fehring2006, wilcox2000
            ),
            line("推算的算法参考 LAPLACE Cycles，感谢它公开了做法。", laplace),
        ],
        hasDiagram: true
    )

    private static let basicsBlock = CycleGuideBlock(
        id: "basics",
        title: "基础知识",
        lead: "一个周期里身体在做什么，多长属于正常，为什么每个人、每一次都不一样。",
        parts: [
            CycleGuidePart(sentences: [
                sentence(
                    "卵巢这边，一个周期分卵泡期、排卵和黄体期，经期是卵泡期开头的几天。",
                    msdCycle
                ),
                sentence("经期出血是子宫内膜脱落排出。", msdCycle, cmaPuberty),
                sentence("经期过后，内膜在雌激素的作用下重新长厚。", msdEndocrinology),
                sentence(
                    "排卵后，黄体分泌的孕激素让内膜继续增厚、准备好迎接胚胎；没有受精时，黄体约 14 天后退化，激素回落，下一次经期开始。",
                    msdCycle
                ),
            ]),
            CycleGuidePart(sentences: [
                sentence(
                    "周期长短的差异主要来自卵泡期，它是三个阶段里长短变化最大的。",
                    msdCycle
                ),
                sentence(
                    "黄体期最稳定，默沙东写平均约 14 天；对 App 用户的实测平均约 12.4 天。",
                    msdEndocrinology, bull2019
                ),
            ]),
            line(
                "中国指南把周期 21–35 天（28±7 天）列为正常范围，近一年里最长和最短的周期相差不到 7 天算规律。",
                chinaAub
            ),
            CycleGuidePart(sentences: [
                sentence(
                    "经期多为 2–7 天，前两天出血最多；中国指南以不超过 7 天为正常，默沙东写的正常范围是 4–8 天。",
                    nhsPeriods, chinaAub, msdCycle
                ),
                sentence("一次经期平均失血约 30 mL，正常范围 5–80 mL。", msdEndocrinology),
            ]),
            line(
                "对 12 万多名经期 App 用户、60 多万个周期的统计里，只有约 13% 的周期正好 28 天；同一个人每次也会差几天。",
                bull2019, fehring2006
            ),
            line(
                "易孕期为什么有好几天：卵子排出后约 12 小时内能受精，精子在体内能存活 3–5 天，所以从排卵前 5 天到排卵后 1 天都可能怀孕，示意图上就是第 10–16 天。",
                msdCycle, wilcox2000
            ),
        ]
    )

    private static let pubertyBlock = CycleGuideBlock(
        id: irregularBlockID,
        title: "青春期",
        lead: "刚开始来月经的几年，周期不规律在一定范围内属于正常；读完能知道这个范围，以及什么情况该看医生。",
        parts: [
            line(
                "全国调查里，中国汉族女孩初潮年龄的中位数 2019 年是 12.0 岁，也就是 12 岁的女孩里大约一半已经来过。",
                ma2023
            ),
            line(
                "不规律多是因为排卵还不规律：控制排卵的下丘脑—垂体—卵巢轴还没发育成熟，卵巢不能按时排卵。",
                cmaPuberty, shaw
            ),
            line(
                "初潮后第一年周期不规律是常见的过渡；初潮后 1–3 年内，周期在 21–45 天之间都还属于正常范围。",
                adolescentAub, acog
            ),
            line(
                "规律的周期通常在初潮后 2–3 年里逐渐建立；默沙东写的是一般 5 年后变得规律。",
                cmaPuberty, msdPuberty
            ),
            line(
                "这些情况该看医生：15 岁还没来过；哪怕只有一次间隔超过 90 天；经期超过 7 天；每 1–2 小时就要换一片卫生巾。",
                acog, adolescentAub
            ),
        ]
    )

    private static let premenstrualBlock = CycleGuideBlock(
        id: "premenstrual",
        title: "经前和经期",
        lead: "经前几天和经期常有哪些不适，为什么会有，一般多久会好。",
        parts: [
            line(
                "经前可能易怒、焦虑、情绪低落、失眠、注意力不集中、很疲倦，身体上可能腹胀、手脚浮肿、乳房胀痛。",
                msdPms, cmaPremenstrual
            ),
            line(
                "什么时候开始、多久消失，说法不一：默沙东写多在经期前 5 天到几小时出现、月经开始后几小时内消失；中华医学会的科普写经前 7–14 天就可能出现，月经来后逐渐缓解。",
                msdPms, cmaPremenstrual
            ),
            line("轻重因人而异，同一个人每个周期也不一样。", msdPms),
            line(
                "原因没有定论，可能和激素水平的起落、大脑里血清素等的变化、遗传等有关。",
                msdPms, cmaPremenstrual
            ),
            line(
                "经期可能下腹痛，痛感可能延到下背或腿，有的还会头痛、恶心、便秘或腹泻；疼痛在开始后约 24 小时最重，2–3 天后消退。",
                msdCramps
            ),
            line(
                "原发性痛经通常从青春期开始，专家认为和经期释放的前列腺素有关：它让子宫收缩，收缩带来疼痛。",
                msdCramps
            ),
            line("痛经会影响 30% 或更多女性的日常活动。", msdCramps),
            line(
                "突然出现或新出现的剧烈疼痛、持续疼痛、发热时，要尽快就医（通常当天）；没有这些，但比平时更痛、痛得更久，也应在几天内就医。",
                msdCramps
            ),
        ]
    )

    private static let healthBlock = CycleGuideBlock(
        id: "health",
        title: "常见健康问题",
        lead: "下面是和经期有关的几种常见问题，不是完整的清单，也不能用来自我诊断。担心自己或身边的人时，可以记下每次经期和症状，看妇科时带给医生。",
        parts: [
            headed(
                "经前综合征",
                sentence(
                    "一组在经期开始前几天出现的身体和心理症状，通常在经期第一天的几小时内结束，常见易怒、焦虑、抑郁、乳房胀痛和头痛。",
                    msdPms
                ),
                sentence(
                    "医生根据症状诊断，通常要每天记下症状；少吃糖、盐和咖啡因、多运动能缓解，也可以用药。",
                    msdPms
                ),
                sentence("美国约 13%–18% 的育龄女性有，全球各地的估计在 1%–50% 之间。", msdPms),
                sentence("症状重到影响生活和工作时，建议及早治疗。", cmaPremenstrual)
            ),
            headed(
                "经前焦虑症",
                sentence(
                    "经前综合征里症状非常严重的一种，会干扰工作、社交或人际关系；可能对日常活动失去兴趣，甚至有自杀的念头，这时要立刻求助。",
                    msdPms
                ),
                sentence(
                    "至少记下两个周期的症状才能诊断；常用抗抑郁药（SSRI），认知行为疗法也可能有帮助。",
                    msdPms
                ),
                sentence("美国约 2%–6% 的女性有。", msdPms)
            ),
            headed(
                "痛经",
                sentence(
                    "找不到别的疾病的叫原发性痛经，通常从青春期开始，更常见；由别的疾病引起的叫继发性痛经，通常成年后才开始，最常见的原因是子宫内膜异位症。",
                    msdCramps
                ),
                sentence(
                    "检查通常包括妊娠检测、体检和超声；布洛芬这类非甾体抗炎药，或再加上含孕激素和雌激素的避孕药，可能缓解疼痛。",
                    msdCramps
                ),
                sentence("突然剧痛、持续疼痛或者发热时，要尽快就医。", msdCramps)
            ),
            headed(
                "月经过多",
                sentence(
                    "属于异常子宫出血：出血比平常更久或更多，默沙东以持续超过 8 天、失血超过约 90 mL 为界，中国指南以经期超过 7 天为异常。",
                    msdAub, chinaAub
                ),
                sentence("出血一直不止，可能导致缺铁、贫血；治疗看原因，可能用激素等药物或手术。", msdAub),
                sentence(
                    "每 1–2 小时就浸透一片卫生巾或一根棉条、排出血块，或者感到头晕，提示出血量大；血里有大血块时应立即就医。",
                    msdVaginalBleeding
                )
            ),
            headed(
                "多囊卵巢综合征",
                sentence(
                    "表现为月经不规律或不来，常伴肥胖，或者雄激素升高引起的体毛多、痤疮；症状通常在青春期出现，只看到卵巢囊肿不足以确诊。",
                    msdPcos
                ),
                sentence(
                    "医生根据症状、查激素的血检和超声诊断；锻炼、减重和含雌激素加孕激素的药物可能减轻症状。",
                    msdPcos
                ),
                sentence("大约 5%–10% 的女性有。", msdPcos)
            ),
            headed(
                "子宫内膜异位症",
                sentence(
                    "本该长在子宫内壁的内膜组织长到了子宫以外，是良性的病；三个典型症状是经期疼痛、性交疼痛和不孕。",
                    msdEndometriosis
                ),
                sentence("确诊通常要做腹腔镜检查；治疗用药物缓解疼痛、减缓异位组织生长。", msdEndometriosis),
                sentence(
                    "有多少女性患病目前还不清楚；在不孕和慢性盆腔痛的女性里比例较高，分别约 30% 和 40%。",
                    msdEndometriosis
                )
            ),
            headed(
                "子宫肌瘤",
                sentence(
                    "女性生殖系统里最常见的非癌性肿块；可能没有症状，也可能引起异常出血、盆腔压迫感或疼痛。",
                    msdFibroids
                ),
                sentence("盆腔检查和超声就能确诊，只在引起不适时才需要治疗。", msdFibroids),
                sentence(
                    "在美国，约 70% 的白人女性和 80% 的黑人女性 50 岁前会长肌瘤，其中约 15%–30% 症状严重。",
                    msdFibroids
                )
            ),
            headed(
                "卵巢囊肿破裂或扭转",
                sentence(
                    "卵巢囊肿多数是良性的，能自行消散；黄体囊肿破裂时，液体流进腹腔，会引起剧烈腹痛。",
                    msdOvarianCysts
                ),
                sentence(
                    "卵巢扭转会阻断它的血供，突然出现剧烈的盆腔疼痛，常伴恶心、呕吐，有的发热；需要立即手术。",
                    msdTorsion
                ),
                sentence("新出现突发的剧烈下腹痛，或者疼痛越来越重时，应立即就医。", msdPelvicPain)
            ),
        ]
    )

    private static let careBlock = CycleGuideBlock(
        id: "care",
        title: "怎么体贴",
        lead: "知道她这几天可能不舒服以后，能做什么、不该做什么。",
        parts: [
            line("让她睡够、多休息；热敷或按摩下腹、规律运动，都可能缓解痛经。", msdCramps),
            line("经前少吃糖、少盐、少咖啡因（巧克力里也有），规律运动，能帮助缓解经前不适。", msdPms),
            line("疼得厉害时，布洛芬这类止痛药可能有帮助；不管用时，医生还有别的办法。", msdCramps),
            line("她不主动提，就别追问，也别拿她的周期说事。", laplaceOvu),
        ]
    )

    private static let mythsBlock = CycleGuideBlock(
        id: "myths",
        title: "常见误区",
        lead: "几种流传很广的说法，和它们为什么不对。",
        parts: [
            headed(
                "❌ 住在一起，月经会同步",
                sentence(
                    "追踪一年多的研究没有发现同步；最早报道同步的研究重新分析后，结果可以用偶然解释。周期本身有波动，两个人的经期会时而靠近、时而分开，看起来像同步。",
                    yang2006
                )
            ),
            headed(
                "❌ 周期都是 28 天，第 14 天排卵",
                sentence(
                    "只有约 13% 的周期正好 28 天；28 天的周期里，最常见的排卵日是第 16 天左右，不是第 14 天。",
                    bull2019, johnson2018
                )
            ),
            headed(
                "❌ 推迟就是怀孕",
                sentence(
                    "推迟不一定是怀孕：过度减肥、体重快速下降、精神压力大、长期剧烈运动，都可能让月经紊乱甚至停止。",
                    cmaPuberty, msdAbsent
                ),
                sentence(
                    "但怀孕仍是育龄女性月经停止最常见的原因，周期页的推算判断不了是否怀孕。",
                    msdAbsent
                )
            ),
            headed(
                "❌「安全期」是安全的",
                sentence(
                    "排卵可能因压力、作息变化提前或推迟；只靠日历推算来避孕，按常规的用法，一年里每 100 人约有 12 人怀孕。",
                    who, gdCdc
                )
            ),
            headed(
                "❌ 记录周期只是为了备孕或避孕",
                sentence(
                    "医生把月经周期看作和体温、血压一样的健康指标；记下来，有异常时能早些发现。",
                    acog
                )
            ),
        ]
    )
}
