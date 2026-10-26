import { describe, expect, it } from "vitest";

import { ApiError } from "@/lib/api";
import { paginate } from "@/lib/barText";
import {
  type BarVisitAction,
  type BarVisitState,
  type VisitLine,
  atTheDoor,
  barVisit,
  doorNotice,
  isArrowShown,
  isSpeaking,
  shownText,
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
    const mixing = run(ENTER, VISIT, line(ORDER, 0), { type: "event", event: { type: "waiting" } }, { type: "tick", now: 5000 });

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
});

describe("点单", () => {
  const ordered = [ENTER, VISIT, line(HELLO, 0), { type: "tap", now: 5000 } as const, line(ORDER, 5000)];
  const MEMO: BarVisitAction = { type: "event", event: { type: "memo", text: "她要 Sugar Rush。" } };
  const WAITING: BarVisitAction = { type: "event", event: { type: "waiting" } };

  it("点单句打完、waiting 也到了，才显示备忘、进入调酒", () => {
    const state = run(...ordered, MEMO, WAITING);

    expect(state).toMatchObject({ isMixing: false, memo: null });
    expect(barVisit(state, { type: "tick", now: 9000 })).toMatchObject({ isMixing: true, memo: "她要 Sugar Rush。" });
  });

  it("点一下打完点单句也算", () => {
    expect(run(...ordered, MEMO, WAITING, { type: "tap", now: 5010 })).toMatchObject({ isMixing: true });
  });

  it("点单句先打完、waiting 后到也一样", () => {
    const typed = run(...ordered, MEMO, { type: "tick", now: 9000 });

    expect(typed).toMatchObject({ isMixing: false, memo: null });
    expect(barVisit(typed, WAITING)).toMatchObject({ isMixing: true, memo: "她要 Sugar Rush。" });
  });

  it("点单句还没打完时，tick 不开调酒台", () => {
    expect(run(...ordered, MEMO, WAITING, { type: "tick", now: 5010 })).toMatchObject({ isMixing: false });
  });

  it("不是点单的句子打完，waiting 到了也不开", () => {
    expect(run(ENTER, VISIT, line(HELLO, 0), WAITING, { type: "tick", now: 9000 })).toMatchObject({ isMixing: false });
  });
});
