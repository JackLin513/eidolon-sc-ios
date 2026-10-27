import { describe, expect, it } from "vitest";

import { emptyMixer } from "@/lib/barMixer";
import { paginate } from "@/lib/barText";
import {
  type BarSceneAction,
  type BarSceneState,
  type SceneLine,
  awaitsLine,
  barScene,
  emptyScene,
  isArrowShown,
  isCounterOpen,
  isSpeaking,
  mixingMemo,
  shownText,
  typingVoice,
} from "@/lib/barScene";

/** Every character as wide as a CJK one. */
const measure = (text: string) => [...text].length * 12;
const NAMES = { her: "真乃", producer: "制作人" };

function line(l: SceneLine, now = 0, extra: { mark?: number; opensCounter?: true } = {}): BarSceneAction {
  return { type: "line", line: l, pages: paginate(l, { names: NAMES, measure }), now, ...extra };
}

const tap = (now: number): BarSceneAction => ({ type: "tap", now });

const HELLO: SceneLine = { speaker: "her", emotion: "happy", ja: "こんばんは", zh: "晚上好" };
const WELCOME: SceneLine = { speaker: "producer", zh: "欢迎光临" };
const ORDER: SceneLine = { speaker: "her", emotion: "thinking", ja: "甘いのを", zh: "要甜的" };
const READY: BarSceneAction = { type: "counterReady", memo: "她要 Sugar Rush。" };

function run(...actions: BarSceneAction[]): BarSceneState {
  return actions.reduce(barScene, emptyScene());
}

describe("打字和翻页", () => {
  it("第一句一到就开始打，每秒 30 字", () => {
    const state = run(line(HELLO, 100));

    expect(shownText(state, 100)?.rows.map((row) => row.text)).toEqual(["", ""]);
    expect(shownText(state, 100 + 100)?.rows.map((row) => row.text)).toEqual(["こんば", "晚上"]);
  });

  it("句子按到达顺序排队，打完一页、点了才翻下一页", () => {
    const state = run(line(HELLO, 0), line(WELCOME, 50));

    expect(shownText(state, 5000)?.line).toEqual(HELLO);
    expect(shownText(barScene(state, tap(5000)), 5000)?.line).toEqual(WELCOME);
  });

  it("点一下先打完整页，再点才翻页", () => {
    const tapped = run(line(HELLO, 0), line(WELCOME, 0), tap(30));

    expect(shownText(tapped, 30)).toMatchObject({ line: HELLO, isTypedOut: true });
    expect(shownText(tapped, 30)?.rows.map((row) => row.text)).toEqual(["こんばんは", "晚上好"]);
    expect(shownText(barScene(tapped, tap(40)), 40)).toMatchObject({ line: WELCOME, isTypedOut: false });
  });

  it("一句分了几页的，一页一页翻", () => {
    const long: SceneLine = { speaker: "producer", zh: "一".repeat(150) };
    const state = run(line(long, 0));

    expect(shownText(state, 10_000)?.rows).toHaveLength(4);
    expect(shownText(barScene(state, tap(10_000)), 10_000)?.rows).toHaveLength(1);
  });

  it("还没点过的，下一句到了也不翻", () => {
    expect(shownText(run(line(HELLO, 0), line(WELCOME, 5000)), 5000)?.line).toEqual(HELLO);
  });
});

describe("等下一句", () => {
  it("翻过最后一页、下一句还没到时文本框等着，再点没用；到了马上打", () => {
    const waited = run(line(HELLO, 0), tap(5000));

    expect(barScene(waited, tap(5100))).toEqual(waited);
    expect(shownText(waited, 5100)?.line).toEqual(HELLO);
    expect(shownText(barScene(waited, line(WELCOME, 6000)), 6000)).toMatchObject({ line: WELCOME, isTypedOut: false });
  });

  it("什么都还没说、或者都点过去了，框就在等下一句；还有没翻的页、框上那页没点过去时不等", () => {
    expect(awaitsLine(emptyScene())).toBe(true);
    const state = run(line(HELLO, 0), line(WELCOME, 0));
    expect(awaitsLine(state)).toBe(false);
    expect(awaitsLine(barScene(state, tap(5000)))).toBe(false);
    expect(awaitsLine([tap(5000), tap(9000)].reduce(barScene, state))).toBe(true);
  });
});

describe("箭头", () => {
  it("打完一页才跳，翻过最后一页等下一句时不跳", () => {
    const state = run(line(HELLO, 0));

    expect(isArrowShown(state, 50)).toBe(false);
    expect(isArrowShown(state, 5000)).toBe(true);
    expect(isArrowShown(barScene(state, tap(5000)), 5000)).toBe(false);
  });
});

describe("她的表情和嘴", () => {
  it("表情跟着框上她那一句，制作人说话时不变；进来时是平静的", () => {
    expect(emptyScene().mood).toBe("calm");
    const state = run(line(HELLO, 0), line(WELCOME, 0));
    expect(state.mood).toBe("happy");
    expect(barScene(state, tap(5000)).mood).toBe("happy");
  });

  it("她的句子打字时开口，打完闭嘴；制作人说话时不开口", () => {
    const state = run(line(HELLO, 0), line(WELCOME, 0));

    expect(isSpeaking(state, 50)).toBe(true);
    expect(isSpeaking(state, 5000)).toBe(false);
    expect(isSpeaking(barScene(state, tap(5000)), 5010)).toBe(false);
  });

  it("打字音效：谁的句子在打就是谁的，打完、点一下打完时停", () => {
    const state = run(line(HELLO, 0), line(WELCOME, 0));
    expect(typingVoice(emptyScene(), 0)).toBeNull();
    expect(typingVoice(state, 50)).toBe("her");
    expect(typingVoice(barScene(state, tap(50)), 60)).toBeNull();

    const producer = barScene(state, tap(5000));
    expect(typingVoice(producer, 5010)).toBe("producer");
    expect(typingVoice(producer, 10_000)).toBeNull();
  });
});

describe("开台", () => {
  const ordered = [line(HELLO, 0), tap(5000), line(ORDER, 5000, { opensCounter: true })];

  it("标了开台的那句打完停在框上、箭头跳着；点过去、可以开台也给了，才开，文本框写备忘", () => {
    const typed = run(...ordered, READY);

    expect(isCounterOpen(typed)).toBe(false);
    expect(isArrowShown(typed, 9000)).toBe(true);
    expect(mixingMemo(typed)).toBeNull();
    const read = barScene(typed, tap(9000));
    expect(isCounterOpen(read)).toBe(true);
    expect(mixingMemo(read)).toBe("她要 Sugar Rush。");
    expect(isArrowShown(read, 9000)).toBe(false);
  });

  it("先点过去、后给可以开台，也开", () => {
    const read = run(...ordered, tap(9000));

    expect(isCounterOpen(read)).toBe(false);
    expect(mixingMemo(barScene(read, READY))).toBe("她要 Sugar Rush。");
  });

  it("那句没打完时点一下只打完，再点一下才开", () => {
    const finished = run(...ordered, READY, tap(5010));

    expect(isCounterOpen(finished)).toBe(false);
    expect(isCounterOpen(barScene(finished, tap(5020)))).toBe(true);
  });

  it("一句分了几页的，最后一页点过去才开", () => {
    const long: SceneLine = { speaker: "producer", zh: "一".repeat(150) };
    const firstRead = run(line(long, 0, { opensCounter: true }), READY, tap(10_000));

    expect(isCounterOpen(firstRead)).toBe(false);
    expect(isCounterOpen(barScene(firstRead, tap(20_000)))).toBe(true);
  });

  it("没标开台的句子点过去，可以开台给了也不开", () => {
    expect(isCounterOpen(run(line(HELLO, 0), READY, tap(9000)))).toBe(false);
  });
});

describe("调酒和上酒后收起", () => {
  const add: BarSceneAction = { type: "mix", action: { type: "add", ingredient: "adelhyde" } };
  const open = run(line(ORDER, 0, { opensCounter: true }), READY, tap(9000));

  it("调酒台开着时才能调，打开时摇酒器是空的", () => {
    expect(open.mixer).toEqual(emptyMixer());
    expect(barScene(open, add).mixer).not.toEqual(emptyMixer());
    const talking = run(line(HELLO, 0));
    expect(barScene(talking, add)).toBe(talking);
  });

  it("收起：调酒台关上、杯子倒掉，下一句一到马上顶掉框上那句开始打", () => {
    const stowed = barScene(barScene(open, add), { type: "stow" });

    expect(isCounterOpen(stowed)).toBe(false);
    expect(stowed.mixer).toEqual(emptyMixer());
    expect(shownText(barScene(stowed, line(WELCOME, 20_000)), 20_000)).toMatchObject({ line: WELCOME, isTypedOut: false });
  });

  it("收起以后再点框上那句，下一次可以开台给了也不开", () => {
    const tappedAgain = barScene(barScene(open, { type: "stow" }), tap(30_000));

    expect(isCounterOpen(barScene(tappedAgain, READY))).toBe(false);
  });
});

describe("清掉某个标记的台词", () => {
  const REACTION: SceneLine = { speaker: "her", emotion: "happy", ja: "おいしい", zh: "好喝" };
  const ENJOY: SceneLine = { speaker: "producer", zh: "请慢用" };
  const clear = (mark: number): BarSceneAction => ({ type: "clear", mark });

  it("打过的和没打的都清；没有之前那一页时框空着，下一句一到就打", () => {
    const state = run(line(HELLO, 0, { mark: 0 }), line(WELCOME, 0, { mark: 0 }), clear(0));

    expect(shownText(state, 100)).toBeNull();
    expect(state.mood).toBe("calm");
    expect(shownText(barScene(state, line(WELCOME, 100, { mark: 0 })), 100)?.line).toEqual(WELCOME);
  });

  it("回到它们之前那一页，显示为已打完、箭头不跳，表情也回到那时的；下一句一到就打", () => {
    const before = run(line(ORDER, 0, { mark: 0 }), tap(5000), line(ENJOY, 5000, { mark: 0 }));
    const state = [line(REACTION, 5000, { mark: 1 }), tap(9000), line(WELCOME, 9000, { mark: 1 }), clear(1)].reduce(barScene, before);

    expect(shownText(state, 9000)).toMatchObject({ line: ENJOY, isTypedOut: true });
    expect(isArrowShown(state, 9000)).toBe(false);
    expect(state.mood).toBe("thinking");
    expect(shownText(barScene(state, line(REACTION, 9500, { mark: 1 })), 9500)).toMatchObject({ line: REACTION, isTypedOut: false });
  });

  it("框上还是别的标记那句时，只清排着的", () => {
    const state = run(line(ENJOY, 0, { mark: 0 }), line(REACTION, 0, { mark: 1 }), clear(1));

    expect(shownText(state, 0)?.line).toEqual(ENJOY);
    expect(shownText(barScene(state, tap(9000)), 9000)?.line).toEqual(ENJOY);
  });
});
