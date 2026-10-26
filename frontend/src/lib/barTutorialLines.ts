// 教程的台词（规格「酒吧的店面」的「教程」，GLOSSARY.md「教程」）：はづき 下班顺路来带第一天当酒保的制作人，
// 点两杯教调酒。台词写死在这里，不调模型；流程（什么时候打开调酒台、上酒后接哪段）也写在每段的 `then` 上，
// 由 `lib/barTutorial` 照着走。
//
// - 她的一句是日语加中文字幕（ADR-0001），制作人的一句只有中文；每句带一个情绪，驱动她的立绘。
// - 打开调酒台的两段（两课）带一句备忘：这一杯的要点，制作人第一人称的心里话，调酒时写在文本框里（票 14）。
// - 饮品名：她的日语用目录的日文名，中文字幕用英文原名（同 `characters/bar_lines.toml`）；材料名两边都用瓶上的英文名。
// - 不讲讨厌的口味、「上得最好」、醉的门槛、电视、键盘快捷键、「离开」（规格的 Out of Scope）。

import type { Emotion } from "@/lib/standAnimations";

export type TutorialLine =
  | { who: "her"; ja: string; zh: string; emotion: Emotion }
  | { who: "producer"; zh: string; emotion: Emotion };

export type TutorialSectionId =
  | "opening"
  | "lesson1"
  | "first.sugar-rush"
  | "first.piano-man"
  | "first.other"
  | "lesson2"
  | "second.moonblast"
  | "second.other"
  | "closing"
  | "jukebox";

/** 一段打完以后接什么。 */
export type TutorialThen =
  /** 接着打这一段。 */
  | { type: "section"; section: TutorialSectionId }
  /** 打开调酒台，文本框写 `memo`（这一杯的要点）；上酒时按上的饮品 id 接一段反应，不在里面的（调成别的）接 `other`。
   * 调坏的上不了，不判。 */
  | { type: "mixer"; memo: string; reactions: { [drinkId: string]: TutorialSectionId; other: TutorialSectionId } }
  /** 教程的台词完了：弹出选曲界面（取不到音频时没有点唱机那段，收尾完了就回店门口）。 */
  | { type: "done" };

export type TutorialSection = {
  lines: readonly TutorialLine[];
  then: TutorialThen;
};

const her = (emotion: Emotion, ja: string, zh: string): TutorialLine => ({ who: "her", ja, zh, emotion });
const producer = (emotion: Emotion, zh: string): TutorialLine => ({ who: "producer", zh, emotion });

/** 教程从这一段开始。 */
export const TUTORIAL_START: TutorialSectionId = "opening";

export const TUTORIAL: Record<TutorialSectionId, TutorialSection> = {
  opening: {
    lines: [
      her("happy", "こんばんは～、プロデューサーさん。お店、開いてますか～？", "晚上好～制作人。店开着吗～？"),
      producer("surprised", "欢迎光临……咦，你怎么来了？"),
      her("happy", "ふふ、事務所の帰りに、ちょっと寄り道です～", "呵呵，从事务所下班，顺路过来看看～"),
      her("calm", "今日からここでバーテンダーさん、なんですよね？", "从今天起，你要在这里当酒保了吧？"),
      producer("calm", "嗯，第一天。说实话，还不太会调。"),
      her("shy", "実は私、前にバーでアルバイトしてたことがあるんです", "其实我以前在酒吧打过工。"),
      her("happy", "今日は私がお客さん役で、少しお手伝いしますね♪", "今天我来当客人，帮你一把吧♪"),
      producer("happy", "那就拜托了。"),
    ],
    then: { type: "section", section: "lesson1" },
  },

  lesson1: {
    lines: [
      her("calm", "じゃあ最初は、シュガーラッシュをお願いします～", "那第一杯，请给我一杯 Sugar Rush～"),
      her("thinking", "作り方は、左上に出るレシピブックに載ってますよ", "做法在配方书里，调酒时会出现在左上方。"),
      her("calm", "上のタブで、名前や味、種類から探せます～", "上面的标签可以按名称、口味、种类来找～"),
      her("calm", "材料の瓶をシェイカーまで引っぱると、一つ分入ります", "把材料瓶拖到摇酒器上，就加进一份。"),
      her("calm", "入れ終わったら『ミックス』、もう一回押すと止まります", "加好了点「调制」，再点一次就停下。"),
      her("happy", "できあがったら、同じボタンをもう一回押せばお出しできます～", "调好以后，再点一次那个按钮，就是上酒～"),
      her("thinking", "失敗しちゃったら『リセット』で、最初からやり直せます", "调坏了就点「重来」，从头再调。"),
      her("calm", "混ぜている途中でも押せますからね～", "摇到一半也能点哦～"),
      her("happy", "ふふ、もしピアノ マンが作れちゃったら、続きの説明は省きますね～", "呵呵，要是你能调出 Piano Man，后面的说明就省了～"),
      producer("calm", "好，我试试。"),
    ],
    then: {
      type: "mixer",
      memo: "她要 Sugar Rush。配方在配方书里查，调坏了就点重做。",
      reactions: { "sugar-rush": "first.sugar-rush", "piano-man": "first.piano-man", other: "first.other" },
    },
  },

  "first.sugar-rush": {
    lines: [
      her("happy", "……ん、甘くておいしいです～。ちゃんとシュガーラッシュですね", "……嗯，甜甜的，很好喝～。是 Sugar Rush 没错。"),
      her("happy", "初めてにしては上出来ですよ、プロデューサーさん", "第一次就调成这样，很不错哦，制作人。"),
      her("calm", "じゃあ、もう一杯いきましょうか～", "那我们再来一杯吧～"),
    ],
    then: { type: "section", section: "lesson2" },
  },

  "first.piano-man": {
    lines: [
      her("surprised", "あら～……これ、ピアノ マンじゃないですか", "哎呀～……这不是 Piano Man 吗。"),
      her("happy", "ふふ、私が教えることなんて、あんまりなさそうですね～", "呵呵，看来没什么需要我教的了～"),
      her("calm", "約束ですから、作り方の説明はここまでにしますね", "说好了的，调法就讲到这里。"),
    ],
    then: { type: "section", section: "closing" },
  },

  "first.other": {
    lines: [
      her("thinking", "ん～……これ、シュガーラッシュではないですね～", "嗯～……这个不是 Sugar Rush 呢～"),
      her("calm", "でも、出していただいたものは、ありがたくいただきますね", "不过上了的，我就心怀感激地喝啦。"),
      her("happy", "次の一杯で、取り返しましょうか～", "下一杯再扳回来吧～"),
    ],
    then: { type: "section", section: "lesson2" },
  },

  lesson2: {
    lines: [
      her("calm", "次は、ムーンブラストをお願いします～", "下一杯，请给我 Moonblast～"),
      her("thinking", "これは『ブレンド』して作るお酒なんです", "这一款要「调和」。"),
      her("calm", "ミックスを押したら、5秒以上待ってから止めてください", "点了「调制」以后，等满 5 秒再停。"),
      her("calm", "シェイカーが速く揺れ出したら、ブレンドになった合図ですよ～", "摇酒器晃得快起来，就是调和好了～"),
      her("thinking", "それと、レシピに氷とあったら、横の『氷』のボタンを押してくださいね", "还有，配方里写了加冰，就按旁边的加冰按钮。"),
      her("calm", "ムーンブラストは、氷入りです～", "Moonblast 是要加冰的～"),
      producer("calm", "等满 5 秒，加冰。记住了。"),
    ],
    then: {
      type: "mixer",
      memo: "她要 Moonblast。按了调制，等满 5 秒再停，还要加冰。",
      reactions: { moonblast: "second.moonblast", other: "second.other" },
    },
  },

  "second.moonblast": {
    lines: [
      her("happy", "……ふふ、冷たくて甘いです～。ちゃんとムーンブラストですね", "……呵呵，冰冰甜甜的～。是 Moonblast 没错。"),
      her("happy", "これなら、安心してお店をお任せできますね", "这样我就放心把店交给你了。"),
    ],
    then: { type: "section", section: "closing" },
  },

  "second.other": {
    lines: [
      her("thinking", "ん～……ムーンブラスト、ではないですね～", "嗯～……这不是 Moonblast 呢～"),
      her("happy", "大丈夫です。ブレンドは慣れですから～", "没关系，调和多做几次就熟了～"),
    ],
    then: { type: "section", section: "closing" },
  },

  closing: {
    lines: [
      her("calm", "あとは、いくつか覚えておいてほしいことを～", "最后，有几件事想让你记住～"),
      her("calm", "『大きいので』と頼まれたら、材料を全部倍にしてください", "客人要大杯，就把材料全部加倍。"),
      her("thinking", "もともと量の多いレシピは、それだけで大きいサイズです", "配方本来份数就多的，本身就是大杯。"),
      her("calm", "氷の隣の『熟成』は、レシピに熟成とあるときに押します", "加冰旁边的「陈化」，配方里写了陈化才按。"),
      her("calm", "Karmotrineはお酒の成分で、入れても味は変わりません", "Karmotrine 是酒精，加了味道也不会变。"),
      her("calm", "レシピに『お好みで』とあれば、入れても入れなくてもいいんです", "配方写着「可任选」的，加不加、加几份都行。"),
      her("thinking", "大きいサイズにするときも、そこは倍にしなくて大丈夫ですよ～", "做大杯的时候，这部分也不用加倍～"),
      her("happy", "でも入れすぎると、お客さんが酔いやすくなっちゃいますから～", "不过加多了，客人就容易醉哦～"),
      her("calm", "それから、お客さんはいつも名前で頼むとは限りません", "还有，客人不一定直接说名字。"),
      her("calm", "『甘いの』とか『おしゃれなの』とか、味や種類だったり", "可能说「甜的」「时尚的」，按口味或种类点；"),
      her("thinking", "いくつか条件をつけたり、何かにたとえたり……", "也可能提几个条件，或者打个比方……"),
      her("happy", "『おまかせで』なんて言われることもありますよ～", "还可能说「你来定吧」～"),
      her("calm", "作っている間は、注文が下に出ますから、忘れても大丈夫です", "调酒的时候，下面会写着点了什么，忘了也不要紧。"),
      her("thinking", "違うものを出すと、ちょっと文句を言われちゃうかもですけど", "上得不对，可能会被抱怨几句，"),
      her("happy", "作り直しはなしですから、気楽にいきましょう～", "不过不用重做，放轻松～"),
      producer("happy", "知道了。谢谢，帮大忙了。"),
      her("happy", "ふふ、どういたしまして。初日、がんばってくださいね～", "呵呵，不客气。第一天，加油哦～"),
    ],
    then: { type: "section", section: "jukebox" },
  },

  jukebox: {
    lines: [
      her("surprised", "あ、そうそう、もうひとつだけ～", "啊对了，还有一件事～"),
      her("calm", "このジュークボックス、先に12曲選ばないと鳴らないんです", "这台点唱机要先选好 12 首才会放。"),
      her("happy", "お店を開ける前に、選んでおいてくださいね～", "开门营业之前，先选好吧～"),
    ],
    then: { type: "done" },
  },
};
