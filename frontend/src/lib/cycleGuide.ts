/**
 * 周期页的讲解七块和「怎么算的」里的示意图（.scratch/cycle-page spec「讲解（七块）」）。
 * 纯数据：块的列表、每句的来源、示意图每格的标法；怎么排版在 `components/play/CycleGuide.tsx`。
 */

/** 一个来源：句末的小链接，新标签页打开。 */
export type GuideSource = { label: string; href: string };

/** 一句话和它的来源；来源不止一个时句末并列。 */
export type GuideSentence = { text: string; sources: GuideSource[] };

/** 一段：几句话，可以带一个小标题（「常见健康问题」的病名、「常见误区」的 ❌ 那条）。 */
export type GuidePart = { heading?: string; sentences: GuideSentence[] };

/** 一块：标题、开头一两句导语、下面几段；`hasDiagram` 时在导语后放示意图。 */
export type GuideBlock = { id: string; title: string; lead: string; parts: GuidePart[]; hasDiagram?: boolean };

/** 示意图一格的类别。 */
export type DiagramKind = "period" | "fertile" | "ovulation" | null;

const EXAMPLE_CYCLE = 28;
const EXAMPLE_PERIOD = 5;
/** 排卵日估作下次经期第一天往前数 14 天。 */
const BEFORE_NEXT = 14;
/** 易孕期：排卵日前 5 天到后 1 天。 */
const FERTILE_BEFORE = 5;
const FERTILE_AFTER = 1;

/** 示意图：以 28 天为例的一条横条，每格是第几天和它的类别。不代入任何一位的数据。 */
export function diagramDays(): { day: number; kind: DiagramKind }[] {
  const ovulation = EXAMPLE_CYCLE + 1 - BEFORE_NEXT;
  return Array.from({ length: EXAMPLE_CYCLE }, (_, i) => {
    const day = i + 1;
    if (day <= EXAMPLE_PERIOD) return { day, kind: "period" };
    if (day === ovulation) return { day, kind: "ovulation" };
    if (day >= ovulation - FERTILE_BEFORE && day <= ovulation + FERTILE_AFTER) return { day, kind: "fertile" };
    return { day, kind: null };
  });
}

const MSD = "https://www.msdmanuals.cn/home/women-s-health-issues";
const MSD_PRO = "https://www.msdmanuals.cn/professional/gynecology-and-obstetrics";
const MSD_BLEEDING = `${MSD}/menstrual-disorders-and-abnormal-uterine-bleeding`;

/** 讲解里用到的来源，标签是句末小链接的字。默沙东不注明的是大众版。 */
const SOURCES = {
  nhsFertility: { label: "NHS", href: "https://www.nhs.uk/conditions/periods/fertility-in-the-menstrual-cycle/" },
  nhsPeriods: { label: "NHS", href: "https://www.nhs.uk/conditions/periods/" },
  msdCycle: { label: "默沙东", href: `${MSD}/biology-of-the-female-reproductive-system/menstrual-cycle` },
  msdEndocrinology: {
    label: "默沙东专业版",
    href: `${MSD_PRO}/female-reproductive-endocrinology/female-reproductive-endocrinology`,
  },
  msdFertilityAwareness: {
    label: "默沙东专业版",
    href: `${MSD_PRO}/family-planning/fertility-awareness-based-methods-of-contraception`,
  },
  msdPuberty: { label: "默沙东", href: `${MSD}/biology-of-the-female-reproductive-system/puberty-in-girls` },
  msdPms: { label: "默沙东", href: `${MSD_BLEEDING}/premenstrual-syndrome-pms` },
  msdCramps: { label: "默沙东", href: `${MSD_BLEEDING}/menstrual-cramps` },
  msdAbsent: { label: "默沙东", href: `${MSD_BLEEDING}/absence-of-menstrual-periods` },
  msdAub: { label: "默沙东", href: `${MSD_BLEEDING}/abnormal-uterine-bleeding-aub` },
  msdVaginalBleeding: { label: "默沙东", href: `${MSD}/symptoms-of-gynecologic-disorders/vaginal-bleeding` },
  msdPelvicPain: { label: "默沙东", href: `${MSD}/symptoms-of-gynecologic-disorders/pelvic-pain-in-women` },
  msdPcos: { label: "默沙东", href: `${MSD_BLEEDING}/polyendocrine-metabolic-ovarian-syndrome-pmos` },
  msdEndometriosis: { label: "默沙东", href: `${MSD}/endometriosis/endometriosis` },
  msdFibroids: { label: "默沙东", href: `${MSD}/fibroids/uterine-fibroids` },
  msdOvarianCysts: {
    label: "默沙东",
    href: `${MSD}/miscellaneous-gynecologic-abnormalities/ovarian-cysts-and-other-benign-ovarian-masses`,
  },
  msdTorsion: { label: "默沙东", href: `${MSD}/miscellaneous-gynecologic-abnormalities/adnexal-torsion` },
  laplacePredictions: { label: "LAPLACE Cycles", href: "https://laplace.live/cycles/predictions?locale=en" },
  laplace: { label: "LAPLACE Cycles", href: "https://laplace.live/cycles" },
  laplaceOvu: { label: "LAPLACE", href: "https://laplace.live/ovu" },
  chinaAub: { label: "中国指南", href: "https://drugs.dxy.cn/pc/clinicalDecision/pdVhB3viFNd_kqK1A_KHR4g" },
  adolescentAub: { label: "中国青春期共识", href: "https://gocm.bmj.com/content/5/1/e000115" },
  acog: {
    label: "ACOG",
    href: "https://www.acog.org/clinical/guidance/committee-opinion/2015/12/menstruation-in-girls-and-adolescents-using-the-menstrual-cycle-as-a-vital-sign",
  },
  cmaPuberty: { label: "中华医学会", href: "https://www.cma.org.cn/art/2022/7/30/art_4584_46755.html" },
  cmaPremenstrual: { label: "中华医学会", href: "https://www.cma.org.cn/art/2022/12/19/art_4584_48741.html" },
  shaw: { label: "Shaw 综述", href: "https://pmc.ncbi.nlm.nih.gov/articles/PMC6570576/" },
  ma2023: { label: "Ma 2023", href: "https://doi.org/10.1007/s12519-023-00723-9" },
  bull2019: { label: "Bull 2019", href: "https://www.nature.com/articles/s41746-019-0152-7" },
  fehring2006: { label: "Fehring 2006", href: "https://epublications.marquette.edu/nursing_fac/11/" },
  wilcox2000: { label: "Wilcox 2000", href: "https://pmc.ncbi.nlm.nih.gov/articles/PMC27529/" },
  johnson2018: { label: "Johnson 2018", href: "https://www.tandfonline.com/doi/full/10.1080/03007995.2018.1475348" },
  yang2006: { label: "Yang 2006", href: "https://doi.org/10.1007/s12110-006-1005-z" },
  who: { label: "WHO", href: "https://www.fphandbook.org/sites/default/files/JHU%20HBk22%20-%20Chapter%2018.pdf" },
  gdCdc: { label: "广东省疾控", href: "https://cdcp.gd.gov.cn/zzzq/jkts/content/post_4779475.html" },
} satisfies Record<string, GuideSource>;

/** 一句话。 */
function say(text: string, ...sources: GuideSource[]): GuideSentence {
  return { text, sources };
}

/** 只有一句的一段。 */
function line(text: string, ...sources: GuideSource[]): GuidePart {
  return { sentences: [say(text, ...sources)] };
}

/** 带小标题的一段。 */
function headed(heading: string, ...sentences: GuideSentence[]): GuidePart {
  return { heading, sentences };
}

/** 「长短不一」那句链到的块。 */
export const IRREGULAR_BLOCK_ID = "puberty";

/**
 * 讲解七块，依次排在周期页最下面。措辞守 .scratch/cycle-page spec「措辞要严谨」：「第 N 天」只从经期第一天数；
 * 各来源说法不同时写范围并注明；引原文的病名照原文（经前综合征、经前焦虑症、痛经、月经过多）。
 */
export const CYCLE_GUIDE: GuideBlock[] = [
  {
    id: "how",
    title: "怎么算的",
    lead: "推算只看记下的日期，按下面几步算。它能估出大概哪天，不能知道她身体里发生了什么。",
    hasDiagram: true,
    parts: [
      line("一个周期从经期第一天算起，到下次经期第一天的前一天为止。", SOURCES.nhsFertility, SOURCES.msdCycle),
      line(
        "只记了一次时，周期按 28 天、经期按 5 天粗略估计：28 天接近人群周期长度的中位数，5 天是常见的经期天数。",
        SOURCES.laplacePredictions,
        SOURCES.nhsPeriods,
      ),
      line(
        "记满两次后，取最近至多 8 个周期长度的中位数。用中位数，是为了不被一次特别长或特别短的周期带偏。",
        SOURCES.laplacePredictions,
      ),
      line(
        "短于 15 天、长于 60 天的间隔先去掉；长到剩下最短那个的 1.6 倍以上的，当作中间漏记了一次，也不算进去，因为一段很长的空档不能说明中间没来过。",
        SOURCES.laplacePredictions,
      ),
      line("经期天数取最近 6 次的中位数。", SOURCES.laplacePredictions),
      line(
        "下次经期第一天是最后一次记下的第一天加上推算的周期，之后每隔一个周期推一次，共 3 次。",
        SOURCES.laplacePredictions,
      ),
      line(
        "周期页把每次推算的经期之前 5 天标作经前，这是我们的设定，依据是默沙东写经前不适多在经期前 5 天到几小时出现。",
        SOURCES.msdPms,
      ),
      line(
        "这几种情况下推算变淡、只作参考：只记了一次；最长和最短的周期差 7 天以上（中国指南也以 7 天为「规律」的界线）；有疑似漏记的间隔被去掉；到了推算的日子还没记下新的一次。",
        SOURCES.laplacePredictions,
        SOURCES.chinaAub,
      ),
      line(
        "「过去的估算平均差」：对每个已经结束的周期，只用它开始之前的记录重算一遍当时的推算，看实际早了或晚了几天，再取平均。",
        SOURCES.laplacePredictions,
      ),
      line(
        "示意图以 28 天为例：下次经期第一天是第 29 天，往前数 14 天，排卵日落在第 15 天；易孕期从排卵日前 5 天到后 1 天，即第 10–16 天。",
        SOURCES.msdFertilityAwareness,
        SOURCES.msdCycle,
      ),
      line(
        "「往前数 14 天」只是近似：排卵到下次经期（黄体期）实测平均约 12.4 天，人和人之间差约 2 天；28 天的周期里，正好在下次经期前 14 天排卵的只有约一成。所以示意图上的排卵日和易孕期只是讲道理用的例子，周期页也不为任何一位推算它们。",
        SOURCES.bull2019,
        SOURCES.fehring2006,
        SOURCES.wilcox2000,
      ),
      line("推算的算法参考 LAPLACE Cycles，感谢它公开了做法。", SOURCES.laplace),
    ],
  },
  {
    id: "basics",
    title: "基础知识",
    lead: "一个周期里身体在做什么，多长属于正常，为什么每个人、每一次都不一样。",
    parts: [
      {
        sentences: [
          say("卵巢这边，一个周期分卵泡期、排卵和黄体期，经期是卵泡期开头的几天。", SOURCES.msdCycle),
          say("经期出血是子宫内膜脱落排出。", SOURCES.msdCycle, SOURCES.cmaPuberty),
          say("经期过后，内膜在雌激素的作用下重新长厚。", SOURCES.msdEndocrinology),
          say(
            "排卵后，黄体分泌的孕激素让内膜继续增厚、准备好迎接胚胎；没有受精时，黄体约 14 天后退化，激素回落，下一次经期开始。",
            SOURCES.msdCycle,
          ),
        ],
      },
      {
        sentences: [
          say("周期长短的差异主要来自卵泡期，它是三个阶段里长短变化最大的。", SOURCES.msdCycle),
          say(
            "黄体期最稳定，默沙东写平均约 14 天；对 App 用户的实测平均约 12.4 天。",
            SOURCES.msdEndocrinology,
            SOURCES.bull2019,
          ),
        ],
      },
      line("中国指南把周期 21–35 天（28±7 天）列为正常范围，近一年里最长和最短的周期相差不到 7 天算规律。", SOURCES.chinaAub),
      {
        sentences: [
          say(
            "经期多为 2–7 天，前两天出血最多；中国指南以不超过 7 天为正常，默沙东写的正常范围是 4–8 天。",
            SOURCES.nhsPeriods,
            SOURCES.chinaAub,
            SOURCES.msdCycle,
          ),
          say("一次经期平均失血约 30 mL，正常范围 5–80 mL。", SOURCES.msdEndocrinology),
        ],
      },
      line(
        "对 12 万多名经期 App 用户、60 多万个周期的统计里，只有约 13% 的周期正好 28 天；同一个人每次也会差几天。",
        SOURCES.bull2019,
        SOURCES.fehring2006,
      ),
      line(
        "易孕期为什么有好几天：卵子排出后约 12 小时内能受精，精子在体内能存活 3–5 天，所以从排卵前 5 天到排卵后 1 天都可能怀孕，示意图上就是第 10–16 天。",
        SOURCES.msdCycle,
        SOURCES.wilcox2000,
      ),
    ],
  },
  {
    id: IRREGULAR_BLOCK_ID,
    title: "青春期",
    lead: "刚开始来月经的几年，周期不规律在一定范围内属于正常；读完能知道这个范围，以及什么情况该看医生。",
    parts: [
      line("全国调查里，中国汉族女孩初潮年龄的中位数 2019 年是 12.0 岁，也就是 12 岁的女孩里大约一半已经来过。", SOURCES.ma2023),
      line(
        "不规律多是因为排卵还不规律：控制排卵的下丘脑—垂体—卵巢轴还没发育成熟，卵巢不能按时排卵。",
        SOURCES.cmaPuberty,
        SOURCES.shaw,
      ),
      line(
        "初潮后第一年周期不规律是常见的过渡；初潮后 1–3 年内，周期在 21–45 天之间都还属于正常范围。",
        SOURCES.adolescentAub,
        SOURCES.acog,
      ),
      line("规律的周期通常在初潮后 2–3 年里逐渐建立；默沙东写的是一般 5 年后变得规律。", SOURCES.cmaPuberty, SOURCES.msdPuberty),
      line(
        "这些情况该看医生：15 岁还没来过；哪怕只有一次间隔超过 90 天；经期超过 7 天；每 1–2 小时就要换一片卫生巾。",
        SOURCES.acog,
        SOURCES.adolescentAub,
      ),
    ],
  },
  {
    id: "premenstrual",
    title: "经前和经期",
    lead: "经前几天和经期常有哪些不适，为什么会有，一般多久会好。",
    parts: [
      line(
        "经前可能易怒、焦虑、情绪低落、失眠、注意力不集中、很疲倦，身体上可能腹胀、手脚浮肿、乳房胀痛。",
        SOURCES.msdPms,
        SOURCES.cmaPremenstrual,
      ),
      line(
        "什么时候开始、多久消失，说法不一：默沙东写多在经期前 5 天到几小时出现、月经开始后几小时内消失；中华医学会的科普写经前 7–14 天就可能出现，月经来后逐渐缓解。",
        SOURCES.msdPms,
        SOURCES.cmaPremenstrual,
      ),
      line("轻重因人而异，同一个人每个周期也不一样。", SOURCES.msdPms),
      line(
        "原因没有定论，可能和激素水平的起落、大脑里血清素等的变化、遗传等有关。",
        SOURCES.msdPms,
        SOURCES.cmaPremenstrual,
      ),
      line(
        "经期可能下腹痛，痛感可能延到下背或腿，有的还会头痛、恶心、便秘或腹泻；疼痛在开始后约 24 小时最重，2–3 天后消退。",
        SOURCES.msdCramps,
      ),
      line(
        "原发性痛经通常从青春期开始，专家认为和经期释放的前列腺素有关：它让子宫收缩，收缩带来疼痛。",
        SOURCES.msdCramps,
      ),
      line("痛经会影响 30% 或更多女性的日常活动。", SOURCES.msdCramps),
      line(
        "突然出现或新出现的剧烈疼痛、持续疼痛、发热时，要尽快就医（通常当天）；没有这些，但比平时更痛、痛得更久，也应在几天内就医。",
        SOURCES.msdCramps,
      ),
    ],
  },
  {
    id: "health",
    title: "常见健康问题",
    lead: "下面是和经期有关的几种常见问题，不是完整的清单，也不能用来自我诊断。担心自己或身边的人时，可以记下每次经期和症状，看妇科时带给医生。",
    parts: [
      headed(
        "经前综合征",
        say(
          "一组在经期开始前几天出现的身体和心理症状，通常在经期第一天的几小时内结束，常见易怒、焦虑、抑郁、乳房胀痛和头痛。",
          SOURCES.msdPms,
        ),
        say(
          "医生根据症状诊断，通常要每天记下症状；少吃糖、盐和咖啡因、多运动能缓解，也可以用药。",
          SOURCES.msdPms,
        ),
        say("美国约 13%–18% 的育龄女性有，全球各地的估计在 1%–50% 之间。", SOURCES.msdPms),
        say("症状重到影响生活和工作时，建议及早治疗。", SOURCES.cmaPremenstrual),
      ),
      headed(
        "经前焦虑症",
        say(
          "经前综合征里症状非常严重的一种，会干扰工作、社交或人际关系；可能对日常活动失去兴趣，甚至有自杀的念头，这时要立刻求助。",
          SOURCES.msdPms,
        ),
        say(
          "至少记下两个周期的症状才能诊断；常用抗抑郁药（SSRI），认知行为疗法也可能有帮助。",
          SOURCES.msdPms,
        ),
        say("美国约 2%–6% 的女性有。", SOURCES.msdPms),
      ),
      headed(
        "痛经",
        say(
          "找不到别的疾病的叫原发性痛经，通常从青春期开始，更常见；由别的疾病引起的叫继发性痛经，通常成年后才开始，最常见的原因是子宫内膜异位症。",
          SOURCES.msdCramps,
        ),
        say(
          "检查通常包括妊娠检测、体检和超声；布洛芬这类非甾体抗炎药，或再加上含孕激素和雌激素的避孕药，可能缓解疼痛。",
          SOURCES.msdCramps,
        ),
        say("突然剧痛、持续疼痛或者发热时，要尽快就医。", SOURCES.msdCramps),
      ),
      headed(
        "月经过多",
        say(
          "属于异常子宫出血：出血比平常更久或更多，默沙东以持续超过 8 天、失血超过约 90 mL 为界，中国指南以经期超过 7 天为异常。",
          SOURCES.msdAub,
          SOURCES.chinaAub,
        ),
        say("出血一直不止，可能导致缺铁、贫血；治疗看原因，可能用激素等药物或手术。", SOURCES.msdAub),
        say(
          "每 1–2 小时就浸透一片卫生巾或一根棉条、排出血块，或者感到头晕，提示出血量大；血里有大血块时应立即就医。",
          SOURCES.msdVaginalBleeding,
        ),
      ),
      headed(
        "多囊卵巢综合征",
        say(
          "表现为月经不规律或不来，常伴肥胖，或者雄激素升高引起的体毛多、痤疮；症状通常在青春期出现，只看到卵巢囊肿不足以确诊。",
          SOURCES.msdPcos,
        ),
        say(
          "医生根据症状、查激素的血检和超声诊断；锻炼、减重和含雌激素加孕激素的药物可能减轻症状。",
          SOURCES.msdPcos,
        ),
        say("大约 5%–10% 的女性有。", SOURCES.msdPcos),
      ),
      headed(
        "子宫内膜异位症",
        say(
          "本该长在子宫内壁的内膜组织长到了子宫以外，是良性的病；三个典型症状是经期疼痛、性交疼痛和不孕。",
          SOURCES.msdEndometriosis,
        ),
        say("确诊通常要做腹腔镜检查；治疗用药物缓解疼痛、减缓异位组织生长。", SOURCES.msdEndometriosis),
        say(
          "有多少女性患病目前还不清楚；在不孕和慢性盆腔痛的女性里比例较高，分别约 30% 和 40%。",
          SOURCES.msdEndometriosis,
        ),
      ),
      headed(
        "子宫肌瘤",
        say(
          "女性生殖系统里最常见的非癌性肿块；可能没有症状，也可能引起异常出血、盆腔压迫感或疼痛。",
          SOURCES.msdFibroids,
        ),
        say("盆腔检查和超声就能确诊，只在引起不适时才需要治疗。", SOURCES.msdFibroids),
        say(
          "在美国，约 70% 的白人女性和 80% 的黑人女性 50 岁前会长肌瘤，其中约 15%–30% 症状严重。",
          SOURCES.msdFibroids,
        ),
      ),
      headed(
        "卵巢囊肿破裂或扭转",
        say("卵巢囊肿多数是良性的，能自行消散；黄体囊肿破裂时，液体流进腹腔，会引起剧烈腹痛。", SOURCES.msdOvarianCysts),
        say(
          "卵巢扭转会阻断它的血供，突然出现剧烈的盆腔疼痛，常伴恶心、呕吐，有的发热；需要立即手术。",
          SOURCES.msdTorsion,
        ),
        say("新出现突发的剧烈下腹痛，或者疼痛越来越重时，应立即就医。", SOURCES.msdPelvicPain),
      ),
    ],
  },
  {
    id: "care",
    title: "怎么体贴",
    lead: "知道她这几天可能不舒服以后，能做什么、不该做什么。",
    parts: [
      line("让她睡够、多休息；热敷或按摩下腹、规律运动，都可能缓解痛经。", SOURCES.msdCramps),
      line("经前少吃糖、少盐、少咖啡因（巧克力里也有），规律运动，能帮助缓解经前不适。", SOURCES.msdPms),
      line("疼得厉害时，布洛芬这类止痛药可能有帮助；不管用时，医生还有别的办法。", SOURCES.msdCramps),
      line("她不主动提，就别追问，也别拿她的周期说事。", SOURCES.laplaceOvu),
    ],
  },
  {
    id: "myths",
    title: "常见误区",
    lead: "几种流传很广的说法，和它们为什么不对。",
    parts: [
      headed(
        "❌ 住在一起，月经会同步",
        say(
          "追踪一年多的研究没有发现同步；最早报道同步的研究重新分析后，结果可以用偶然解释。周期本身有波动，两个人的经期会时而靠近、时而分开，看起来像同步。",
          SOURCES.yang2006,
        ),
      ),
      headed(
        "❌ 周期都是 28 天，第 14 天排卵",
        say(
          "只有约 13% 的周期正好 28 天；28 天的周期里，最常见的排卵日是第 16 天左右，不是第 14 天。",
          SOURCES.bull2019,
          SOURCES.johnson2018,
        ),
      ),
      headed(
        "❌ 推迟就是怀孕",
        say(
          "推迟不一定是怀孕：过度减肥、体重快速下降、精神压力大、长期剧烈运动，都可能让月经紊乱甚至停止。",
          SOURCES.cmaPuberty,
          SOURCES.msdAbsent,
        ),
        say("但怀孕仍是育龄女性月经停止最常见的原因，周期页的推算判断不了是否怀孕。", SOURCES.msdAbsent),
      ),
      headed(
        "❌「安全期」是安全的",
        say(
          "排卵可能因压力、作息变化提前或推迟；只靠日历推算来避孕，按常规的用法，一年里每 100 人约有 12 人怀孕。",
          SOURCES.who,
          SOURCES.gdCdc,
        ),
      ),
      headed(
        "❌ 记录周期只是为了备孕或避孕",
        say("医生把月经周期看作和体温、血压一样的健康指标；记下来，有异常时能早些发现。", SOURCES.acog),
      ),
    ],
  },
];
