import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import type { Drink } from "@/lib/api";
import {
  type BarMixerState,
  barMixer,
  canServe,
  CAPACITY,
  emptyMixer,
  FAST_AFTER_MS,
  type Ingredient,
  INGREDIENTS,
  matchDrink,
  served,
  shakeStage,
  totalParts,
  slotText,
} from "@/lib/barMixer";

/** The repository's catalog as `GET /api/bar` reads it (backend `Drink.described`), read off
 * `characters/drinks.toml` at run time: the frontend's Docker build has no `characters/`. */
function catalog(): Drink[] {
  const toml = readFileSync(new URL("../../../characters/drinks.toml", import.meta.url), "utf-8");
  const tables: Record<string, unknown>[] = [];
  for (const raw of toml.split("\n")) {
    const line = raw.trim();
    if (line === "[[drinks]]") tables.push({});
    const pair = /^(\w+)\s*=\s*(.+)$/.exec(line);
    if (pair && tables.length > 0) tables[tables.length - 1][pair[1]] = JSON.parse(pair[2]);
  }
  return tables.map(({ name_ja: _, ...t }) => {
    if (t.method === "bottle") return t as Drink;
    const { description: __, ...mixed } = t;
    return { big: false, ...mixed } as Drink;
  });
}

const DRINKS = catalog();
const MIXED = DRINKS.filter((d): d is Exclude<Drink, { method: "bottle" }> => d.method !== "bottle");
const drink = (id: string) => DRINKS.find((d) => d.id === id)!;

/** The mixer with `parts` put in, on ice and aged as given. */
function filled(parts: Partial<Record<Ingredient, number>>, { ice = false, aged = false } = {}): BarMixerState {
  let state = emptyMixer();
  for (const ingredient of INGREDIENTS) {
    for (let i = 0; i < (parts[ingredient] ?? 0); i++) state = barMixer(state, { type: "add", ingredient });
  }
  if (ice) state = barMixer(state, { type: "ice" });
  if (aged) state = barMixer(state, { type: "aged" });
  return state;
}

/** `state` shaken for `ms` and stopped. */
function shaken(state: BarMixerState, ms: number, garble = "##20%!!"): BarMixerState {
  const started = barMixer(state, { type: "shake", now: 1000 });
  return barMixer(started, { type: "stop", now: 1000 + ms, drinks: DRINKS, garble });
}

/** The recipe of a mixed drink put in, `times` over, Karmotrine `optional` as `k` parts. */
function recipeOf(d: Drink, times = 1, k = 0): BarMixerState {
  if (d.method === "bottle") throw new Error(d.id);
  const karmotrine = d.karmotrine === "optional" ? k : d.karmotrine * times;
  const parts = {
    adelhyde: d.adelhyde * times,
    bronson_extract: d.bronson_extract * times,
    powdered_delta: d.powdered_delta * times,
    flanergide: d.flanergide * times,
    karmotrine,
  };
  return shaken(filled(parts, { ice: d.ice, aged: d.aged }), d.method === "blend" ? FAST_AFTER_MS : FAST_AFTER_MS - 1);
}

describe("加料", () => {
  it("一份一份加，加到总共 20 份为止", () => {
    let state = filled({ adelhyde: 15, karmotrine: 5 });
    expect(state.parts).toMatchObject({ adelhyde: 15, karmotrine: 5 });
    const full = state;
    state = barMixer(state, { type: "add", ingredient: "flanergide" });
    expect(state).toBe(full);
    expect(totalParts(full)).toBe(CAPACITY);
  });

  it("减一份，减到 0 为止", () => {
    const one = filled({ bronson_extract: 1 });
    const none = barMixer(one, { type: "remove", ingredient: "bronson_extract" });
    expect(none.parts.bronson_extract).toBe(0);
    expect(barMixer(none, { type: "remove", ingredient: "bronson_extract" })).toBe(none);
  });

  it("冰、陈化是开关", () => {
    const on = filled({}, { ice: true, aged: true });
    expect([on.ice, on.aged]).toEqual([true, true]);
    const off = barMixer(barMixer(on, { type: "ice" }), { type: "aged" });
    expect([off.ice, off.aged]).toEqual([false, false]);
  });

  it("摇起来以后不能再加、减、开关冰和陈化", () => {
    const shaking = barMixer(filled({ adelhyde: 2 }), { type: "shake", now: 0 });
    for (const action of [
      { type: "add", ingredient: "adelhyde" },
      { type: "remove", ingredient: "adelhyde" },
      { type: "ice" },
      { type: "aged" },
    ] as const) {
      expect(barMixer(shaking, action)).toBe(shaking);
    }
  });
});

describe("摇", () => {
  it("空的摇不起来", () => {
    const empty = emptyMixer();
    expect(barMixer(empty, { type: "shake", now: 0 })).toBe(empty);
  });

  it("不到 5 秒慢摇、停下是 mix；满 5 秒快摇、停下是 blend", () => {
    const shaking = barMixer(filled({ adelhyde: 2, powdered_delta: 1 }), { type: "shake", now: 1000 });
    expect(shakeStage(shaking, 1000 + FAST_AFTER_MS - 1)).toBe("slow");
    expect(shakeStage(shaking, 1000 + FAST_AFTER_MS)).toBe("fast");
    expect(shaken(filled({ adelhyde: 2, powdered_delta: 1 }), FAST_AFTER_MS - 1).method).toBe("mix");
    expect(shaken(filled({ adelhyde: 2, powdered_delta: 1 }), FAST_AFTER_MS).method).toBe("blend");
    expect(shakeStage(emptyMixer(), 0)).toBe("still");
    expect(shakeStage(shaken(filled({ adelhyde: 1 }), 0), 99_999)).toBe("stopped");
  });

  it("没在摇时停不了", () => {
    const still = filled({ adelhyde: 1 });
    expect(barMixer(still, { type: "stop", now: 0, drinks: DRINKS, garble: "" })).toBe(still);
  });

  it("重来倒掉一切，次数不限；空的倒不了", () => {
    const made = shaken(filled({ adelhyde: 2, powdered_delta: 1 }, { ice: true }), 10);
    const poured = barMixer(made, { type: "reset" });
    expect(poured).toEqual(emptyMixer());
    expect(barMixer(poured, { type: "reset" })).toBe(poured);
    expect(barMixer(filled({}, { aged: true }), { type: "reset" })).toEqual(emptyMixer());
  });
});

describe("匹配", () => {
  it("目录里是原版的 24 款调制和 4 款瓶装", () => {
    expect(MIXED).toHaveLength(24);
    expect(DRINKS.length - MIXED.length).toBe(4);
  });

  it("每款的配方匹配到它自己", () => {
    for (const d of MIXED) expect(recipeOf(d).made, d.id).toEqual({ drink: d, big: false });
  });

  it("每款不是本身就大的，份数全部翻倍是它的大杯", () => {
    for (const d of MIXED) {
      if (d.big) continue;
      expect(recipeOf(d, 2).made, d.id).toEqual({ drink: d, big: true });
    }
  });

  it("本身就大的没有翻倍版，本身就大的照它自己的份数是大杯", () => {
    const bigs = MIXED.filter((d) => d.big);
    expect(bigs.map((d) => d.id).sort()).toEqual(["marsblast", "piano-man", "piano-woman", "zen-star"]);
    for (const d of bigs) {
      expect(recipeOf(d).made, d.id).toEqual({ drink: d, big: false });
      // 翻倍以后超过 20 份或者对不上：都是调坏的。
      expect(matchDrink(DRINKS, { ...served2x(d), method: d.method }), d.id).toBeNull();
    }
  });

  it("可选的 Karmotrine 加 0 份、加几份都是这一款", () => {
    const sugarRush = drink("sugar-rush");
    expect(recipeOf(sugarRush, 1, 5).made).toEqual({ drink: sugarRush, big: false });
    expect(recipeOf(sugarRush, 2, 3).made).toEqual({ drink: sugarRush, big: true });
  });

  it("份数、冰、陈化、调法差一样就是调坏的", () => {
    const sugarRush = { adelhyde: 2, powdered_delta: 1 };
    expect(shaken(filled(sugarRush), 10).made).not.toBeNull();
    expect(shaken(filled({ ...sugarRush, flanergide: 1 }), 10).made).toBeNull();
    expect(shaken(filled(sugarRush, { ice: true }), 10).made).toBeNull();
    // Sugar Rush 陈化就是 Sparkle Star。
    expect(shaken(filled(sugarRush, { aged: true }), 10).made?.drink.id).toBe("sparkle-star");
    expect(shaken(filled(sugarRush), FAST_AFTER_MS).made).toBeNull();
    // Moonblast 的 Karmotrine 不是可选的：差一份就不是。
    expect(shaken(filled({ adelhyde: 6, powdered_delta: 1, flanergide: 1, karmotrine: 1 }, { ice: true }), FAST_AFTER_MS).made).toBeNull();
  });

  it("隐藏的 Flaming Moai 不在目录里，它的配方是调坏的", () => {
    const moai = shaken(filled({ adelhyde: 1, bronson_extract: 1, powdered_delta: 2, flanergide: 3, karmotrine: 5 }), 10);
    expect(moai.made).toBeNull();
  });
});

/** A big drink's recipe doubled, as a mixture. */
function served2x(d: Drink) {
  if (d.method === "bottle") throw new Error(d.id);
  const k = d.karmotrine === "optional" ? 0 : d.karmotrine;
  return {
    adelhyde: d.adelhyde * 2,
    bronson_extract: d.bronson_extract * 2,
    powdered_delta: d.powdered_delta * 2,
    flanergide: d.flanergide * 2,
    karmotrine: k * 2,
    ice: d.ice,
    aged: d.aged,
  };
}

describe("瓶装", () => {
  const absinthe = drink("absinthe");

  it("只能拖进空的摇酒器", () => {
    const withBottle = barMixer(emptyMixer(), { type: "bottle", drink: absinthe });
    expect(withBottle.bottle).toBe(absinthe);
    const notEmpty = filled({ adelhyde: 1 });
    expect(barMixer(notEmpty, { type: "bottle", drink: absinthe })).toBe(notEmpty);
    expect(barMixer(withBottle, { type: "bottle", drink: drink("rum") })).toBe(withBottle);
    const iced = filled({}, { ice: true });
    expect(barMixer(iced, { type: "bottle", drink: absinthe })).toBe(iced);
  });

  it("调制的饮品拖不进来", () => {
    const empty = emptyMixer();
    expect(barMixer(empty, { type: "bottle", drink: drink("beer") })).toBe(empty);
  });

  it("拖进去以后不能加材料、开关冰和陈化、摇，重来倒掉", () => {
    const withBottle = barMixer(emptyMixer(), { type: "bottle", drink: absinthe });
    for (const action of [
      { type: "add", ingredient: "karmotrine" },
      { type: "ice" },
      { type: "aged" },
      { type: "shake", now: 0 },
    ] as const) {
      expect(barMixer(withBottle, action)).toBe(withBottle);
    }
    expect(barMixer(withBottle, { type: "reset" })).toEqual(emptyMixer());
  });
});

describe("上酒", () => {
  it("停了而且没调坏才能上；瓶装拖进来就能上", () => {
    const mixture = filled({ adelhyde: 2, powdered_delta: 1 });
    expect(canServe(mixture)).toBe(false);
    expect(canServe(barMixer(mixture, { type: "shake", now: 0 }))).toBe(false);
    expect(canServe(shaken(mixture, 10))).toBe(true);
    expect(canServe(shaken(filled({ adelhyde: 1 }), 10))).toBe(false);
    expect(canServe(barMixer(emptyMixer(), { type: "bottle", drink: drink("rum") }))).toBe(true);
  });

  it("上酒的正文：调制的是五种材料的份数、冰、陈化和调法", () => {
    const moonblast = shaken(filled({ adelhyde: 6, powdered_delta: 1, flanergide: 1, karmotrine: 2 }, { ice: true }), 6000);
    expect(served(moonblast)).toEqual({
      method: "blend",
      adelhyde: 6,
      bronson_extract: 0,
      powdered_delta: 1,
      flanergide: 1,
      karmotrine: 2,
      ice: true,
      aged: false,
    });
  });

  it("上酒的正文：瓶装的是哪一瓶", () => {
    expect(served(barMixer(emptyMixer(), { type: "bottle", drink: drink("a-fedora") }))).toEqual({
      method: "bottle",
      bottle: "a-fedora",
    });
  });

  it("服务器说调坏了：照服务器的显示故障瓶", () => {
    const made = shaken(filled({ adelhyde: 2, powdered_delta: 1 }), 10);
    const broken = barMixer(made, { type: "broken", garble: "%%!!?#0" });
    expect([broken.made, canServe(broken), slotText(broken)]).toEqual([null, false, "%%!!?#0"]);
    const bottled = barMixer(barMixer(emptyMixer(), { type: "bottle", drink: drink("rum") }), { type: "broken", garble: "@@" });
    expect([bottled.bottle, bottled.made, canServe(bottled)]).toEqual([null, null, false]);
  });
});

describe("份数槽写什么", () => {
  it("停下前什么都不写", () => {
    expect(slotText(filled({ adelhyde: 3 }))).toBeNull();
    expect(slotText(barMixer(filled({ adelhyde: 3 }), { type: "shake", now: 0 }))).toBeNull();
  });

  it("停下后写短名", () => {
    expect(slotText(recipeOf(drink("fluffy-dream")))).toBe("Flff Dream");
  });

  it("调坏的写乱码", () => {
    expect(slotText(shaken(filled({ adelhyde: 1 }), 10, "#%!0?@&"))).toBe("#%!0?@&");
  });

  it("瓶装的写它的短名", () => {
    expect(slotText(barMixer(emptyMixer(), { type: "bottle", drink: drink("a-fedora") }))).toBe("Plumfume");
  });
});
