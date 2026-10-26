import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { barCatalog } from "@/lib/barCatalogFixture";
import type { BarMixerAction, Ingredient } from "@/lib/barMixer";
import type { TextPage } from "@/lib/barText";
import { type BarTutorialState, barTutorial, beginTutorial, hasSeenTutorial, keepTutorialSeen } from "@/lib/barTutorial";
import { TUTORIAL } from "@/lib/barTutorialLines";
import type { VisitLine } from "@/lib/barVisit";

const DRINKS = barCatalog();

/** 一句一页：只看说到哪了，不管怎么折行。 */
const layout = (line: VisitLine): TextPage[] => [{ rows: [{ name: null, text: line.zh, subtitle: false }] }];

let clock = 0;
const later = () => (clock += 10);

function begin(hasJukebox = true): BarTutorialState {
  return beginTutorial({ characterId: "hazuki", hasJukebox, layout, now: later() });
}

/** 一直点文本框，点到调酒台打开、或者教程走完。 */
function talkThrough(state: BarTutorialState): BarTutorialState {
  for (let i = 0; i < 1000; i++) {
    if (state.visit.isMixing || state.end !== null) return state;
    state = barTutorial(state, { type: "tap", now: later() });
  }
  throw new Error("the tutorial never stopped talking");
}

/** 框上那一句。 */
const onBox = (state: BarTutorialState) => state.visit.shown?.line.zh;

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
    expect(state.visit.stage).toBe("visit");
    expect(state.visit.visit?.characterId).toBe("hazuki");
    expect(onBox(state)).toBe(TUTORIAL.opening.lines[0].zh);
    expect(state.visit.memo).toBeNull();
  });

  it("opens the bar counter only once the first lesson is told, with its memo for the text box", () => {
    let state = begin();
    for (let i = 0; i < 5; i++) state = barTutorial(state, { type: "tap", now: later() });
    expect(state.visit.isMixing).toBe(false);
    expect(state.visit.memo).toBeNull();
    state = talkThrough(state);
    expect(state.visit.isMixing).toBe(true);
    expect(onBox(state)).toBe(TUTORIAL.lesson1.lines.at(-1)!.zh);
    expect(state.visit.memo).toBe(memoOf("lesson1"));
  });
});

describe("serving in the tutorial", () => {
  it("goes on to her reaction to Sugar Rush made right, then the second lesson", () => {
    let state = serve(talkThrough(begin()), SUGAR_RUSH);
    expect(state.visit.isMixing).toBe(false);
    expect(state.section).toBe("first.sugar-rush");
    expect(onBox(state)).toBe(TUTORIAL["first.sugar-rush"].lines[0].zh);
    state = talkThrough(state);
    expect(state.section).toBe("lesson2");
    expect(state.visit.isMixing).toBe(true);
    expect(state.visit.memo).toBe(memoOf("lesson2"));
  });

  it("goes on to her reaction to something else, then the second lesson all the same", () => {
    let state = serve(talkThrough(begin()), BAD_TOUCH);
    expect(state.section).toBe("first.other");
    expect(onBox(state)).toBe(TUTORIAL["first.other"].lines[0].zh);
    state = talkThrough(state);
    expect(state.section).toBe("lesson2");
  });

  it("skips the second lesson for Piano Man, straight to the closing", () => {
    let state = serve(talkThrough(begin()), PIANO_MAN);
    expect(state.section).toBe("first.piano-man");
    expect(onBox(state)).toBe(TUTORIAL["first.piano-man"].lines[0].zh);
    const sections = new Set([state.section]);
    while (state.end === null) {
      state = barTutorial(state, { type: "tap", now: later() });
      sections.add(state.section);
    }
    expect(sections).not.toContain("lesson2");
    expect(sections).toContain("closing");
    expect(state.end).toBe("jukebox");
  });

  it("goes on to her reaction to something else for the second, then the closing", () => {
    const other = serve(talkThrough(serve(talkThrough(begin()), SUGAR_RUSH)), SUGAR_RUSH);
    expect(other.section).toBe("second.other");
    const closing = talkThrough(barTutorial(other, { type: "tap", now: later() }));
    expect(closing.end).toBe("jukebox");
  });

  it("does not take a broken drink: the counter stays open, nothing said", () => {
    const open = talkThrough(begin());
    const broken = mix(open, { parts: { karmotrine: 21 } });
    expect(broken.visit.mixer.shake).toBe("stopped");
    const after = barTutorial(broken, { type: "serve", now: later() });
    expect(after).toBe(broken);
    expect(after.visit.isMixing).toBe(true);
    expect(after.section).toBe("lesson1");
  });

  it("does not serve before the counter opens", () => {
    const state = begin();
    expect(barTutorial(state, { type: "serve", now: later() })).toBe(state);
  });
});

describe("the tutorial's end", () => {
  /** 从头走到底，记下走过的段落。 */
  function walk(hasJukebox: boolean) {
    let state = talkThrough(begin(hasJukebox));
    state = talkThrough(serve(state, SUGAR_RUSH));
    const sections: string[] = [];
    state = serve(state, MOONBLAST);
    while (state.end === null) {
      if (sections.at(-1) !== state.section) sections.push(state.section);
      state = barTutorial(state, { type: "tap", now: later() });
    }
    return { state, sections };
  }

  it("goes on to her reaction to Moonblast made right, then the jukebox section, to the jukebox setup", () => {
    const { state, sections } = walk(true);
    expect(sections).toEqual(["second.moonblast", "closing", "jukebox"]);
    expect(state.end).toBe("jukebox");
  });

  it("leaves out the jukebox section with no audio, straight to the door", () => {
    const { state, sections } = walk(false);
    expect(sections).toEqual(["second.moonblast", "closing"]);
    expect(state.end).toBe("door");
  });

  it("skips to the jukebox setup at once, mid-talk or mixing", () => {
    expect(barTutorial(begin(), { type: "skip" }).end).toBe("jukebox");
    expect(barTutorial(talkThrough(begin()), { type: "skip" }).end).toBe("jukebox");
    expect(barTutorial(begin(false), { type: "skip" }).end).toBe("door");
  });

  it("takes nothing more once ended", () => {
    const ended = barTutorial(begin(), { type: "skip" });
    expect(barTutorial(ended, { type: "tap", now: later() })).toBe(ended);
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
    let state = serve(talkThrough(begin()), PIANO_MAN);
    while (state.end === null) state = barTutorial(state, { type: "tap", now: later() });
    keepTutorialSeen("u1", state);
    expect(hasSeenTutorial("u1")).toBe(true);
    expect(hasSeenTutorial("u2")).toBe(false);
  });

  it("is seen skipped", () => {
    keepTutorialSeen("u2", barTutorial(begin(), { type: "skip" }));
    expect(hasSeenTutorial("u2")).toBe(true);
  });
});
