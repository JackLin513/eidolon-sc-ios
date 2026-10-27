import { describe, expect, it } from "vitest";

import { ApiError, type Drink } from "@/lib/api";
import { type BarMixerAction, emptyMixer } from "@/lib/barMixer";
import { isArrowShown, isCounterOpen, mixingMemo, shownText } from "@/lib/barScene";
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

describe("点单", () => {
  it("点单句点过去、waiting 也到了，经场景开台，文本框写 memo 推来的备忘", () => {
    const typed = run(
      ENTER,
      VISIT,
      line(ORDER, 0),
      { type: "event", event: { type: "memo", text: "她要 Sugar Rush。" } },
      { type: "event", event: { type: "waiting" } },
    );

    expect(isCounterOpen(typed.scene)).toBe(false);
    const read = barVisit(typed, { type: "tap", now: 9000 });
    expect(isCounterOpen(read.scene)).toBe(true);
    expect(mixingMemo(read.scene)).toBe("她要 Sugar Rush。");
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

  it("上酒：送出去时调酒台锁住，再按没用（双击）", () => {
    const serving = barVisit(ready, { type: "serve" });

    expect(serving.isServing).toBe(true);
    expect(isCounterOpen(serving.scene)).toBe(true);
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

    expect(served.isServing).toBe(false);
    expect(isCounterOpen(served.scene)).toBe(false);
    expect(served.scene.mixer).toEqual(emptyMixer());
    const enjoy = barVisit(served, line({ speaker: "producer", zh: "请慢用" }, 20_000));
    expect(shownText(enjoy.scene, 20_000)?.line).toEqual({ speaker: "producer", zh: "请慢用" });
  });

  it("422：照服务器的显示故障瓶，别的什么都不发生", () => {
    const refused = barVisit(barVisit(ready, { type: "serve" }), { type: "serveRefused", status: 422, garble: "%%!!" });

    expect(refused).toMatchObject({ isServing: false, stage: "visit" });
    expect(isCounterOpen(refused.scene)).toBe(true);
    expect([refused.scene.mixer.made, refused.scene.mixer.garble]).toEqual([null, "%%!!"]);
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

    expect(again).toMatchObject({ stage: "next", visit: null, notice: null });
    expect(shownText(again.scene, 9000)).toBeNull();
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

    expect(shownText(state.scene, 100)).toBeNull();
    expect(shownText(barVisit(state, line(WELCOME, 100)).scene, 100)?.line).toEqual(WELCOME);
  });

  it("上酒那次：「请慢用」留着，从它接着", () => {
    const reacted = [line(ENJOY, 20_000), line(REACTION, 20_000), { type: "tap", now: 30_000 } as const];
    const state = [...reacted, RETRYING].reduce(barVisit, servedVisit());

    expect(shownText(state.scene, 30_000)).toMatchObject({ line: ENJOY, isTypedOut: true });
    expect(isArrowShown(state.scene, 30_000)).toBe(false);
    expect(shownText(barVisit(state, line(REACTION, 30_500)).scene, 30_500)).toMatchObject({ line: REACTION, isTypedOut: false });
  });

  it("「请慢用」还在框上时，只清排着的", () => {
    const state = [line(ENJOY, 20_000), line(REACTION, 20_000), RETRYING].reduce(barVisit, servedVisit());

    expect(shownText(state.scene, 20_000)?.line).toEqual(ENJOY);
    expect(shownText(barVisit(state, { type: "tap", now: 30_000 }).scene, 30_000)?.line).toEqual(ENJOY);
  });
});

describe("failed 和再试一次", () => {
  const FAILED: BarVisitAction = { type: "event", event: { type: "failed", message: "模型没有回应，再试一次吧" } };
  const failed = [line(ENJOY, 20_000), line(REACTION, 20_000), { type: "tap", now: 30_000 } as const, FAILED].reduce(
    barVisit,
    servedVisit(),
  );

  it("文本框写出错的话；点文本框没用", () => {
    expect(failed.failure).toBe("模型没有回应，再试一次吧");
    expect(barVisit(failed, { type: "tap", now: 40_000 })).toBe(failed);
  });

  it("再试一次：请求在路上时再点没用；服务器接了，清掉出错这次的句子，「请慢用」留着", () => {
    const retrying = barVisit(failed, { type: "retry" });
    expect(retrying.isRetrying).toBe(true);
    expect(barVisit(retrying, { type: "retry" })).toBe(retrying);

    const retried = barVisit(retrying, { type: "retried" });
    expect(retried).toMatchObject({ failure: null, isRetrying: false });
    expect(shownText(retried.scene, 40_000)?.line).toEqual(ENJOY);
    expect(shownText(barVisit(retried, line(REACTION, 40_000)).scene, 40_000)?.line).toEqual(REACTION);
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
      lines.push(shownText(at.scene, now)!.line);
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
