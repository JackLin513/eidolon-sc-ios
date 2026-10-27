import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { barCatalog } from "@/lib/barCatalogFixture";
import type { BarMixerAction, Ingredient } from "@/lib/barMixer";
import { isArrowShown, isCounterOpen, mixingMemo, type SceneLine, shownText } from "@/lib/barScene";
import type { TextPage } from "@/lib/barText";
import { type BarTutorialState, barTutorial, beginTutorial, hasSeenTutorial, keepTutorialSeen } from "@/lib/barTutorial";
import { TUTORIAL, type TutorialSectionId } from "@/lib/barTutorialLines";

const DRINKS = barCatalog();

/** 一句一页：只看说到哪了，不管怎么折行。 */
const layout = (line: SceneLine): TextPage[] => [{ rows: [{ name: null, text: line.zh, subtitle: false }] }];

let clock = 0;
const later = () => (clock += 10);

function begin(hasJukebox = true): BarTutorialState {
  return beginTutorial({ characterId: "hazuki", hasJukebox, layout, now: later() });
}

const tap = (state: BarTutorialState) => barTutorial(state, { type: "tap", now: later() });

/** 一直点文本框，点到调酒台打开、或者教程走完。 */
function talkThrough(state: BarTutorialState): BarTutorialState {
  for (let i = 0; i < 1000; i++) {
    if (isCounterOpen(state.scene) || state.end !== null) return state;
    state = tap(state);
  }
  throw new Error("the tutorial never stopped talking");
}

/** 框上那一句。 */
const onBox = (state: BarTutorialState) => shownText(state.scene, clock)?.line.zh;

/** 一段的第一句、最后一句。 */
const firstOf = (id: TutorialSectionId) => TUTORIAL[id].lines[0].zh;
const lastOf = (id: TutorialSectionId) => TUTORIAL[id].lines.at(-1)!.zh;

/** 点到教程走完，记下框上出现过的句子。 */
function tapToEnd(state: BarTutorialState): { state: BarTutorialState; said: string[] } {
  const said: string[] = [];
  while (state.end === null) {
    const line = onBox(state);
    if (line !== undefined && said.at(-1) !== line) said.push(line);
    state = tap(state);
  }
  return { state, said };
}

type Recipe = { parts: Partial<Record<Ingredient, number>>; ice?: true; blend?: true };
const SUGAR_RUSH: Recipe = { parts: { adelhyde: 2, powdered_delta: 1 } };
const PIANO_MAN: Recipe = { parts: { adelhyde: 2, bronson_extract: 3, powdered_delta: 5, flanergide: 5, karmotrine: 3 }, ice: true };
const MOONBLAST: Recipe = { parts: { adelhyde: 6, powdered_delta: 1, flanergide: 1, karmotrine: 2 }, ice: true, blend: true };
/** 调对了别的一杯。 */
const BAD_TOUCH: Recipe = { parts: { bronson_extract: 2, powdered_delta: 2, flanergide: 2, karmotrine: 4 }, ice: true };

/** 在开着的调酒台上照 `recipe` 调好（停下）。 */
function mix(state: BarTutorialState, recipe: Recipe): BarTutorialState {
  const actions: BarMixerAction[] = [];
  for (const [ingredient, n] of Object.entries(recipe.parts) as [Ingredient, number][]) {
    for (let i = 0; i < n; i++) actions.push({ type: "add", ingredient });
  }
  if (recipe.ice) actions.push({ type: "ice" });
  const shakenAt = later();
  actions.push({ type: "shake", now: shakenAt });
  actions.push({ type: "stop", now: shakenAt + (recipe.blend ? 6000 : 1000), drinks: DRINKS, garble: "#%!?@&*" });
  return actions.reduce((s, action) => barTutorial(s, { type: "mix", action }), state);
}

function serve(state: BarTutorialState, recipe: Recipe): BarTutorialState {
  return barTutorial(mix(state, recipe), { type: "serve", now: later() });
}

/** The memo a lesson's bar counter opens with, for the text box. */
function memoOf(id: "lesson1" | "lesson2"): string {
  const then = TUTORIAL[id].then;
  if (then.type !== "mixer") throw new Error(`${id} opens no counter`);
  return then.memo;
}

describe("the tutorial", () => {
  it("opens on her first line, no memo", () => {
    const state = begin();
    expect(onBox(state)).toBe(firstOf("opening"));
    expect(mixingMemo(state.scene)).toBeNull();
  });

  it("opens the bar counter only once the first lesson is told, with its memo for the text box", () => {
    let state = begin();
    for (let i = 0; i < 5; i++) state = tap(state);
    expect(mixingMemo(state.scene)).toBeNull();
    state = talkThrough(state);
    expect(onBox(state)).toBe(lastOf("lesson1"));
    expect(mixingMemo(state.scene)).toBe(memoOf("lesson1"));
  });

  it("keeps the lesson's last line on the box, typed out, the arrow bobbing, till it is tapped past", () => {
    let state = begin();
    while (onBox(state) !== lastOf("lesson1")) state = tap(state);
    // 早就打完了，没点也不开。
    clock += 60_000;
    expect(isArrowShown(state.scene, clock)).toBe(true);
    expect(mixingMemo(state.scene)).toBeNull();
    const open = tap(state);
    expect(isArrowShown(open.scene, clock)).toBe(false);
    expect(mixingMemo(open.scene)).toBe(memoOf("lesson1"));
  });
});

describe("serving in the tutorial", () => {
  it("goes on to her reaction to Sugar Rush made right, the counter stowed, then the second lesson", () => {
    let state = serve(talkThrough(begin()), SUGAR_RUSH);
    expect(mixingMemo(state.scene)).toBeNull();
    expect(onBox(state)).toBe(firstOf("first.sugar-rush"));
    expect(shownText(state.scene, clock)?.isTypedOut).toBe(false);
    state = talkThrough(state);
    expect(onBox(state)).toBe(lastOf("lesson2"));
    expect(mixingMemo(state.scene)).toBe(memoOf("lesson2"));
  });

  it("goes on to her reaction to something else, then the second lesson all the same", () => {
    let state = serve(talkThrough(begin()), BAD_TOUCH);
    expect(onBox(state)).toBe(firstOf("first.other"));
    state = talkThrough(state);
    expect(mixingMemo(state.scene)).toBe(memoOf("lesson2"));
  });

  it("skips the second lesson for Piano Man, straight to the closing", () => {
    const state = serve(talkThrough(begin()), PIANO_MAN);
    expect(onBox(state)).toBe(firstOf("first.piano-man"));
    const { state: ended, said } = tapToEnd(state);
    expect(said).not.toContain(firstOf("lesson2"));
    expect(said).toContain(firstOf("closing"));
    expect(ended.end).toBe("jukebox");
  });

  it("goes on to her reaction to something else for the second, then the closing", () => {
    const other = serve(talkThrough(serve(talkThrough(begin()), SUGAR_RUSH)), SUGAR_RUSH);
    expect(onBox(other)).toBe(firstOf("second.other"));
    const { state, said } = tapToEnd(other);
    expect(said).toContain(firstOf("closing"));
    expect(state.end).toBe("jukebox");
  });

  it("does not take a broken drink: the counter stays open, nothing said", () => {
    const broken = mix(talkThrough(begin()), { parts: { karmotrine: 21 } });
    const after = barTutorial(broken, { type: "serve", now: later() });
    expect(after).toBe(broken);
    expect(mixingMemo(after.scene)).toBe(memoOf("lesson1"));
  });

  it("does not serve before the counter opens", () => {
    const state = begin();
    expect(barTutorial(state, { type: "serve", now: later() })).toBe(state);
  });
});

describe("the tutorial's end", () => {
  /** 从头走到底，记下第二杯以后框上出现过的句子。 */
  function walk(hasJukebox: boolean) {
    const state = talkThrough(serve(talkThrough(begin(hasJukebox)), SUGAR_RUSH));
    return tapToEnd(serve(state, MOONBLAST));
  }

  it("goes on to her reaction to Moonblast made right, then the jukebox section, to the jukebox setup", () => {
    const { state, said } = walk(true);
    expect(said[0]).toBe(firstOf("second.moonblast"));
    expect(said).toContain(firstOf("closing"));
    expect(said.at(-1)).toBe(lastOf("jukebox"));
    expect(state.end).toBe("jukebox");
  });

  it("leaves out the jukebox section with no audio, straight to the door", () => {
    const { state, said } = walk(false);
    expect(said).not.toContain(firstOf("jukebox"));
    expect(said.at(-1)).toBe(lastOf("closing"));
    expect(state.end).toBe("door");
  });

  it("skips to the jukebox setup at once, mid-talk or mixing", () => {
    expect(barTutorial(begin(), { type: "skip" }).end).toBe("jukebox");
    expect(barTutorial(talkThrough(begin()), { type: "skip" }).end).toBe("jukebox");
    expect(barTutorial(begin(false), { type: "skip" }).end).toBe("door");
  });

  it("takes nothing more once ended", () => {
    const ended = barTutorial(begin(), { type: "skip" });
    expect(tap(ended)).toBe(ended);
  });
});

describe("the tutorial seen on this device", () => {
  beforeEach(() => {
    const items = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (key: string) => items.get(key) ?? null,
      setItem: (key: string, value: string) => void items.set(key, value),
      removeItem: (key: string) => void items.delete(key),
    });
  });
  afterEach(() => vi.unstubAllGlobals());

  it("is not seen left part-way", () => {
    keepTutorialSeen("u1", talkThrough(begin()));
    expect(hasSeenTutorial("u1")).toBe(false);
  });

  it("is seen done, per user", () => {
    const { state } = tapToEnd(serve(talkThrough(begin()), PIANO_MAN));
    keepTutorialSeen("u1", state);
    expect(hasSeenTutorial("u1")).toBe(true);
    expect(hasSeenTutorial("u2")).toBe(false);
  });

  it("is seen skipped", () => {
    keepTutorialSeen("u2", barTutorial(begin(), { type: "skip" }));
    expect(hasSeenTutorial("u2")).toBe(true);
  });
});
