import { describe, expect, it } from "vitest";

import { ApiError, type Drink } from "@/lib/api";
import { type BarMixerAction, emptyMixer } from "@/lib/barMixer";
import { paginate } from "@/lib/barText";
import {
  type BarVisitAction,
  type BarVisitState,
  type VisitLine,
  type VisitRewarded,
  atTheDoor,
  barVisit,
  doorNotice,
  endCard,
  isArrowShown,
  isSpeaking,
  mixingMemo,
  shownText,
  typingVoice,
} from "@/lib/barVisit";

/** Every character as wide as a CJK one. */
const measure = (text: string) => [...text].length * 12;
const NAMES = { her: "真乃", producer: "制作人" };

function line(l: VisitLine, now = 0): BarVisitAction {
  return { type: "line", line: l, pages: paginate(l, { names: NAMES, measure }), now };
}

const HELLO: VisitLine = { speaker: "her", emotion: "happy", ja: "こんばんは", zh: "晚上好" };
const WELCOME: VisitLine = { speaker: "producer", zh: "欢迎光临" };
const ORDER: VisitLine = { speaker: "her", emotion: "thinking", ja: "甘いのを", zh: "要甜的", order: true };

function run(...actions: BarVisitAction[]): BarVisitState {
  return actions.reduce(barVisit, atTheDoor());
}

const ENTER: BarVisitAction = { type: "enter" };
const VISIT: BarVisitAction = { type: "event", event: { type: "visit", visit_id: "v1", character_id: "mano" } };

describe("进门", () => {
  it("点一下进门，等接口回来时还在店门口，再点没用", () => {
    const entering = run(ENTER);

    expect(entering.stage).toBe("entering");
    expect(barVisit(entering, ENTER)).toBe(entering);
  });

  it("收到 visit 进店，记下光顾和她是谁", () => {
    expect(run(ENTER, VISIT)).toMatchObject({ stage: "visit", visit: { id: "v1", characterId: "mano" } });
  });

  it("进不了门时回店门口，写上为什么", () => {
    const refused = run(ENTER, { type: "refused", notice: "进不了门" });

    expect(refused).toMatchObject({ stage: "door", notice: "进不了门" });
    expect(barVisit(refused, ENTER)).toMatchObject({ stage: "entering", notice: null });
  });

  it("离开以后回到店门口，这次光顾就没了", () => {
    expect(run(ENTER, VISIT, line(HELLO), { type: "left" })).toEqual(atTheDoor());
  });
});

describe("店门口的提示", () => {
  const overLimit = (retryAt: string | null, message = "这一小时的光顾次数已经用完了（每小时 3 次）。") =>
    new ApiError(message, 429, { retryAt });

  it("超了限额写几点以后再来，取到分钟、不会早", () => {
    const at = new Date(2026, 9, 26, 21, 4, 10);

    expect(doorNotice(overLimit(at.toISOString()), new Date(2026, 9, 26, 20, 30))).toBe(
      "这一小时的光顾次数用完了，21:05 以后再来",
    );
  });

  it("过了半夜的写上日期", () => {
    const at = new Date(2026, 9, 27, 0, 3);

    expect(doorNotice(overLimit(at.toISOString()), new Date(2026, 9, 26, 23, 30))).toBe(
      "这一小时的光顾次数用完了，10月27日 00:03 以后再来",
    );
  });

  it("只能用自带密钥（retry_at 为 null）时照文字回合的写法，就是服务器的话", () => {
    expect(doorNotice(overLimit(null, "你的光顾只能用自带密钥，可以在设置里填写。"))).toBe(
      "你的光顾只能用自带密钥，可以在设置里填写。",
    );
  });

  it("别的错误、没有回答，写一句短的", () => {
    expect(doorNotice(new ApiError("Internal Server Error", 500))).toBe("没能进门，再点一下试试");
    expect(doorNotice(null)).toBe("没能进门，再点一下试试");
  });
});

describe("台词", () => {
  it("第一句一到就开始打", () => {
    const state = run(ENTER, VISIT, line(HELLO, 100));

    expect(shownText(state, 100)?.rows.map((row) => row.text)).toEqual(["", ""]);
    expect(shownText(state, 100 + 100)?.rows.map((row) => row.text)).toEqual(["こんば", "晚上"]);
  });

  it("句子按到达顺序排队，打完一页、点了才翻下一页", () => {
    const state = run(ENTER, VISIT, line(HELLO, 0), line(WELCOME, 50));

    expect(shownText(state, 5000)?.line).toEqual(HELLO);
    expect(shownText(barVisit(state, { type: "tap", now: 5000 }), 5000)?.line).toEqual(WELCOME);
  });

  it("点一下先打完整句，再点才翻页", () => {
    const tapped = run(ENTER, VISIT, line(HELLO, 0), line(WELCOME, 0), { type: "tap", now: 30 });

    expect(shownText(tapped, 30)).toMatchObject({ line: HELLO, isTypedOut: true });
    expect(shownText(tapped, 30)?.rows.map((row) => row.text)).toEqual(["こんばんは", "晚上好"]);
    expect(shownText(barVisit(tapped, { type: "tap", now: 40 }), 40)).toMatchObject({ line: WELCOME, isTypedOut: false });
  });

  it("一句分了几页的，一页一页翻", () => {
    const long: VisitLine = { speaker: "producer", zh: "一".repeat(150) };
    const state = run(ENTER, VISIT, line(long, 0));
    const second = barVisit(state, { type: "tap", now: 10_000 });

    expect(shownText(state, 10_000)?.rows).toHaveLength(4);
    expect(shownText(second, 10_000)?.rows).toHaveLength(1);
  });

  it("翻到最后、下一句还没到时文本框等着，到了马上打", () => {
    const waited = run(ENTER, VISIT, line(HELLO, 0), { type: "tap", now: 5000 });

    expect(barVisit(waited, { type: "tap", now: 5100 })).toEqual(waited);
    expect(shownText(waited, 5100)?.line).toEqual(HELLO);
    const arrived = barVisit(waited, line(WELCOME, 6000));
    expect(shownText(arrived, 6000)).toMatchObject({ line: WELCOME, isTypedOut: false });
  });

  it("还没点过的，下一句到了也不翻", () => {
    const state = run(ENTER, VISIT, line(HELLO, 0), line(WELCOME, 5000));

    expect(shownText(state, 5000)?.line).toEqual(HELLO);
  });
});

describe("右下角的箭头", () => {
  it("打完一页才跳，翻过最后一页等下一句时不跳", () => {
    const state = run(ENTER, VISIT, line(HELLO, 0));

    expect(isArrowShown(state, 50)).toBe(false);
    expect(isArrowShown(state, 5000)).toBe(true);
    expect(isArrowShown(barVisit(state, { type: "tap", now: 5000 }), 5000)).toBe(false);
  });

  it("调酒时不跳", () => {
    const mixing = run(ENTER, VISIT, line(ORDER, 0), { type: "event", event: { type: "waiting" } }, { type: "tap", now: 5000 });

    expect(mixing.isMixing).toBe(true);
    expect(isArrowShown(mixing, 5000)).toBe(false);
  });
});

describe("立绘", () => {
  it("她的情绪跟着她正在打的那句，制作人说话时不变", () => {
    expect(run(ENTER, VISIT).mood).toBe("calm");
    const state = run(ENTER, VISIT, line(HELLO, 0), line(WELCOME, 0));
    expect(state.mood).toBe("happy");
    expect(barVisit(state, { type: "tap", now: 5000 }).mood).toBe("happy");
  });

  it("她的句子打字时开口，打完闭嘴；制作人说话时不开口", () => {
    const state = run(ENTER, VISIT, line(HELLO, 0), line(WELCOME, 0));

    expect(isSpeaking(state, 50)).toBe(true);
    expect(isSpeaking(state, 5000)).toBe(false);
    expect(isSpeaking(barVisit(state, { type: "tap", now: 5000 }), 5010)).toBe(false);
  });

  it("打字音效：她的句子打字时是她的，制作人的是制作人的，打完、点一下打完时停", () => {
    const state = run(ENTER, VISIT, line(HELLO, 0), line(WELCOME, 0));
    expect(typingVoice(atTheDoor(), 0)).toBeNull();
    expect(typingVoice(state, 50)).toBe("her");
    expect(typingVoice(barVisit(state, { type: "tap", now: 50 }), 60)).toBeNull();

    const producer = barVisit(state, { type: "tap", now: 5000 });
    expect(typingVoice(producer, 5010)).toBe("producer");
    expect(typingVoice(producer, 10000)).toBeNull();
  });
});

describe("点单", () => {
  const ordered = [ENTER, VISIT, line(HELLO, 0), { type: "tap", now: 5000 } as const, line(ORDER, 5000)];
  const MEMO: BarVisitAction = { type: "event", event: { type: "memo", text: "她要 Sugar Rush。" } };
  const WAITING: BarVisitAction = { type: "event", event: { type: "waiting" } };

  it("点单句打完停在框上、箭头跳着，点过去、waiting 也到了，才进入调酒、文本框写备忘", () => {
    const typed = run(...ordered, MEMO, WAITING);

    expect(typed).toMatchObject({ isMixing: false });
    expect(isArrowShown(typed, 9000)).toBe(true);
    expect(mixingMemo(typed)).toBeNull();
    const read = barVisit(typed, { type: "tap", now: 9000 });
    expect(read).toMatchObject({ isMixing: true });
    expect(mixingMemo(read)).toBe("她要 Sugar Rush。");
  });

  it("点单句没打完时点一下只打完整句，再点一下才开", () => {
    const finished = run(...ordered, MEMO, WAITING, { type: "tap", now: 5010 });

    expect(finished).toMatchObject({ isMixing: false });
    expect(barVisit(finished, { type: "tap", now: 5020 })).toMatchObject({ isMixing: true });
  });

  it("点过点单句、waiting 后到也一样", () => {
    const read = run(...ordered, MEMO, { type: "tap", now: 9000 });

    expect(read).toMatchObject({ isMixing: false });
    expect(barVisit(read, WAITING)).toMatchObject({ isMixing: true });
  });

  it("不是点单的句子点过去，waiting 到了也不开", () => {
    expect(run(ENTER, VISIT, line(HELLO, 0), WAITING, { type: "tap", now: 9000 })).toMatchObject({ isMixing: false });
  });

  it("上过酒以后再点框上那句点单，下一单的 waiting 到了也不开", () => {
    const tappedAgain = barVisit(servedVisit(), { type: "tap", now: 30_000 });

    expect(barVisit(tappedAgain, WAITING)).toMatchObject({ isMixing: false });
  });
});

describe("调酒和上酒", () => {
  const SUGAR_RUSH: Drink = {
    id: "sugar-rush",
    name: "Sugar Rush",
    short_name: "Sugar Rush",
    flavor: "sweet",
    kind: "girly",
    method: "mix",
    adelhyde: 2,
    bronson_extract: 0,
    powdered_delta: 1,
    flanergide: 0,
    karmotrine: "optional",
    ice: false,
    aged: false,
    big: false,
    page: 21,
  };
  const DRINKS = [SUGAR_RUSH];
  const mix = (action: BarMixerAction): BarVisitAction => ({ type: "mix", action });
  const mixing = run(
    ENTER,
    VISIT,
    line(ORDER, 0),
    { type: "event", event: { type: "memo", text: "她要 Sugar Rush。" } },
    { type: "event", event: { type: "waiting" } },
    { type: "tap", now: 9000 },
  );
  const made = [
    mix({ type: "add", ingredient: "adelhyde" }),
    mix({ type: "add", ingredient: "adelhyde" }),
    mix({ type: "add", ingredient: "powdered_delta" }),
    mix({ type: "shake", now: 10_000 }),
    mix({ type: "stop", now: 11_000, drinks: DRINKS, garble: "##" }),
  ];
  const ready = made.reduce(barVisit, mixing);

  it("调酒台开着时才能调；打开时摇酒器是空的", () => {
    expect(mixing.mixer).toEqual(emptyMixer());
    const talking = run(ENTER, VISIT, line(HELLO, 0));
    expect(barVisit(talking, mix({ type: "add", ingredient: "adelhyde" }))).toBe(talking);
  });

  it("上酒：送出去时调酒台锁住，再按没用（双击）", () => {
    const serving = barVisit(ready, { type: "serve" });

    expect(serving).toMatchObject({ isServing: true, isMixing: true });
    expect(barVisit(serving, { type: "serve" })).toBe(serving);
    expect(barVisit(serving, mix({ type: "reset" }))).toBe(serving);
  });

  it("没停、调坏的上不了", () => {
    const shaking = made.slice(0, 4).reduce(barVisit, mixing);
    expect(barVisit(shaking, { type: "serve" })).toBe(shaking);
    const broken = barVisit(barVisit(ready, mix({ type: "reset" })), mix({ type: "add", ingredient: "flanergide" }));
    const stopped = [mix({ type: "shake", now: 0 }), mix({ type: "stop", now: 10, drinks: DRINKS, garble: "##" })].reduce(barVisit, broken);
    expect(barVisit(stopped, { type: "serve" })).toBe(stopped);
  });

  it("服务器收下了：调酒台收起，「请慢用」一到马上打", () => {
    const served = barVisit(barVisit(ready, { type: "serve" }), { type: "served" });

    expect(served).toMatchObject({ isServing: false, isMixing: false, isAwaitingLine: true, memo: "她要 Sugar Rush。" });
    expect(served.mixer).toEqual(emptyMixer());
    const enjoy = barVisit(served, line({ speaker: "producer", zh: "请慢用" }, 20_000));
    expect(shownText(enjoy, 20_000)?.line).toEqual({ speaker: "producer", zh: "请慢用" });
  });

  it("422：照服务器的显示故障瓶，别的什么都不发生", () => {
    const refused = barVisit(barVisit(ready, { type: "serve" }), { type: "serveRefused", status: 422, garble: "%%!!" });

    expect(refused).toMatchObject({ isServing: false, isMixing: true, stage: "visit" });
    expect([refused.mixer.made, refused.mixer.garble]).toEqual([null, "%%!!"]);
  });

  it("410：回店门口，写这次光顾已经结束了", () => {
    const gone = barVisit(barVisit(ready, { type: "serve" }), { type: "serveRefused", status: 410, garble: "" });

    expect(gone).toEqual({ ...atTheDoor(), notice: "这次光顾已经结束了" });
  });

  it("409（双击）和别的错误：照旧，可以再上", () => {
    const refused = barVisit(barVisit(ready, { type: "serve" }), { type: "serveRefused", status: 409, garble: "" });

    expect(refused).toEqual(ready);
  });
});

describe("结束卡", () => {
  const FAREWELL: VisitLine = { speaker: "her", emotion: "happy", ja: "またね", zh: "再见" };
  const done = (rewarded: VisitRewarded): BarVisitAction => ({ type: "event", event: { type: "done", rewarded } });
  const saidGoodbye = [ENTER, VISIT, line(FAREWELL, 0)];

  it("done 到了，最后一句打完、点过了才出", () => {
    const state = run(...saidGoodbye, done(null));

    expect(endCard(state)).toBeNull();
    expect(endCard(barVisit(state, { type: "tap", now: 9000 }))).toEqual({ draws: false, affinityUp: false });
  });

  it("最后一句先点过了，done 一到就出", () => {
    const tapped = run(...saidGoodbye, { type: "tap", now: 9000 });

    expect(endCard(tapped)).toBeNull();
    expect(endCard(barVisit(tapped, done(null)))).not.toBeNull();
  });

  it("后面还有没翻的页时不出", () => {
    const state = run(...saidGoodbye, line(WELCOME, 0), done(null), { type: "tap", now: 9000 });

    expect(endCard(state)).toBeNull();
    expect(endCard(barVisit(state, { type: "tap", now: 9000 }))).toBeNull();
    expect(endCard(barVisit(barVisit(state, { type: "tap", now: 20_000 }), { type: "tap", now: 20_000 }))).not.toBeNull();
  });

  it("三种写法：抽奖和好感度、只有其中一样、什么都没有", () => {
    const card = (rewarded: VisitRewarded) => endCard(run(...saidGoodbye, done(rewarded), { type: "tap", now: 9000 }));

    expect(card({ draws: 1, affinity_up: true })).toEqual({ draws: true, affinityUp: true });
    expect(card({ draws: 0, affinity_up: true })).toEqual({ draws: false, affinityUp: true });
    expect(card({ draws: 0, affinity_up: false })).toEqual({ draws: false, affinityUp: false });
    expect(card(null)).toEqual({ draws: false, affinityUp: false });
  });

  it("再营业：不回店门口，等下一位进门", () => {
    const ended = run(...saidGoodbye, done(null), { type: "tap", now: 9000 });
    const again = barVisit(ended, { type: "again" });

    expect(again).toMatchObject({ stage: "next", visit: null, shown: null, notice: null });
    expect(endCard(again)).toBeNull();
    expect(barVisit(again, VISIT)).toMatchObject({ stage: "visit", visit: { id: "v1" } });
    expect(barVisit(again, { type: "refused", notice: "进不了门" })).toMatchObject({ stage: "door", notice: "进不了门" });
  });

  it("结束卡出来之前，再营业没用", () => {
    const state = run(...saidGoodbye, done(null));

    expect(barVisit(state, { type: "again" })).toBe(state);
  });
});

/** A visit at her first drink served (taken), the producer's 「请慢用」 not come yet. */
function servedVisit(): BarVisitState {
  const mixing = run(
    ENTER,
    VISIT,
    line(ORDER, 0),
    { type: "event", event: { type: "memo", text: "她要 Bad Touch。" } },
    { type: "event", event: { type: "waiting" } },
    { type: "tap", now: 9000 },
  );
  const beer: Drink = {
    id: "beer",
    name: "Beer",
    short_name: "Beer",
    flavor: "bubbly",
    kind: "classic",
    method: "bottle",
    description: "",
    karmotrine: 1,
  };
  const bottled = barVisit(mixing, { type: "mix", action: { type: "bottle", drink: beer } });
  return barVisit(barVisit(bottled, { type: "serve" }), { type: "served" });
}

const ENJOY: VisitLine = { speaker: "producer", zh: "请慢用" };
const REACTION: VisitLine = { speaker: "her", emotion: "happy", ja: "おいしい", zh: "好喝" };
const RETRYING: BarVisitAction = { type: "event", event: { type: "retrying" } };

describe("retrying", () => {
  it("清掉这次调用推来的句子，打过的和没打的都清；下一句一到就打", () => {
    const state = run(ENTER, VISIT, line(HELLO, 0), line(WELCOME, 0), RETRYING);

    expect(state).toMatchObject({ shown: null, queue: [] });
    expect(shownText(barVisit(state, line(WELCOME, 100)), 100)?.line).toEqual(WELCOME);
  });

  it("上酒那次：「请慢用」留着，从它接着", () => {
    const reacted = [line(ENJOY, 20_000), line(REACTION, 20_000), { type: "tap", now: 30_000 } as const];
    const state = [...reacted, RETRYING].reduce(barVisit, servedVisit());

    expect(state.queue).toEqual([]);
    expect(shownText(state, 30_000)).toMatchObject({ line: ENJOY, isTypedOut: true });
    expect(isArrowShown(state, 30_000)).toBe(false);
    expect(shownText(barVisit(state, line(REACTION, 30_500)), 30_500)).toMatchObject({ line: REACTION, isTypedOut: false });
  });

  it("她的情绪也回到这次调用之前", () => {
    expect(run(ENTER, VISIT, line(HELLO, 0), RETRYING).mood).toBe("calm");
    const state = [line(ENJOY, 20_000), line(REACTION, 20_000), { type: "tap", now: 30_000 } as const, RETRYING].reduce(
      barVisit,
      servedVisit(),
    );
    expect(state.mood).toBe("thinking");
  });

  it("「请慢用」还在框上时，只清排着的", () => {
    const state = [line(ENJOY, 20_000), line(REACTION, 20_000), RETRYING].reduce(barVisit, servedVisit());

    expect(state.queue).toEqual([]);
    expect(shownText(state, 20_000)?.line).toEqual(ENJOY);
  });
});

describe("failed 和再试一次", () => {
  const FAILED: BarVisitAction = { type: "event", event: { type: "failed", message: "模型没有回应，再试一次吧" } };
  const failed = [line(ENJOY, 20_000), line(REACTION, 20_000), { type: "tap", now: 30_000 } as const, FAILED].reduce(
    barVisit,
    servedVisit(),
  );

  it("文本框写出错的话；点文本框没用，箭头不出、不开口", () => {
    expect(failed.failure).toBe("模型没有回应，再试一次吧");
    expect(barVisit(failed, { type: "tap", now: 40_000 })).toBe(failed);
    expect(isArrowShown(failed, 40_000)).toBe(false);
    expect(isSpeaking(failed, 30_010)).toBe(false);
  });

  it("再试一次：请求在路上时再点没用；服务器接了，清掉出错这次的句子，「请慢用」留着", () => {
    const retrying = barVisit(failed, { type: "retry" });
    expect(retrying.isRetrying).toBe(true);
    expect(barVisit(retrying, { type: "retry" })).toBe(retrying);

    const retried = barVisit(retrying, { type: "retried" });
    expect(retried).toMatchObject({ failure: null, isRetrying: false, queue: [] });
    expect(shownText(retried, 40_000)?.line).toEqual(ENJOY);
    expect(shownText(barVisit(retried, line(REACTION, 40_000)), 40_000)?.line).toEqual(REACTION);
  });

  it("没出错时再试一次没用", () => {
    const talking = run(ENTER, VISIT, line(HELLO, 0));

    expect(barVisit(talking, { type: "retry" })).toBe(talking);
  });

  it("409（not_failed）忽略，照旧可以再点", () => {
    expect(barVisit(barVisit(failed, { type: "retry" }), { type: "retryRefused", status: 409 })).toEqual(failed);
  });

  it("410 回店门口，写这次光顾已经结束了", () => {
    const gone = barVisit(barVisit(failed, { type: "retry" }), { type: "retryRefused", status: 410 });

    expect(gone).toEqual({ ...atTheDoor(), notice: "这次光顾已经结束了" });
  });

  it("告别两次都失败：清掉推过的，兜底的告别照常打完、出结束卡", () => {
    const FIXED: VisitLine = { speaker: "her", emotion: "calm", ja: "じゃあね", zh: "那我走了" };
    const state = [
      line(ENJOY, 20_000),
      line(REACTION, 20_000),
      RETRYING,
      line(FIXED, 21_000),
      { type: "event", event: { type: "done", rewarded: { draws: 1, affinity_up: true } } } as const,
    ].reduce(barVisit, servedVisit());

    const lines: VisitLine[] = [];
    let at = state;
    for (let now = 30_000; !endCard(at); now += 10_000) {
      lines.push(at.shown!.line);
      at = barVisit(at, { type: "tap", now });
    }
    expect(lines).toEqual([ENJOY, FIXED]);
    expect(endCard(at)).toEqual({ draws: true, affinityUp: true });
  });
});

describe("这次光顾没了", () => {
  it("调用断了、请求得 410：回店门口，写这次光顾已经结束了", () => {
    const state = run(ENTER, VISIT, line(HELLO, 0));

    expect(barVisit(state, { type: "gone" })).toEqual({ ...atTheDoor(), notice: "这次光顾已经结束了" });
  });
});
