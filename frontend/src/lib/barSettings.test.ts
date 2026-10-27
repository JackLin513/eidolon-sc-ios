import { afterAll, afterEach, describe, expect, it, vi } from "vitest";

import {
  DEFAULT_SETTINGS,
  gainOf,
  keepSettings,
  knobX,
  SLIDER,
  stepVolume,
  storedSettings,
  volumeAt,
} from "@/lib/barSettings";

describe("音量", () => {
  it("一格是 10%，满的是原音量", () => {
    expect(gainOf(0)).toBe(0);
    expect(gainOf(3)).toBeCloseTo(0.3);
    expect(gainOf(10)).toBe(1);
  });

  it("−/+ 一次一格，到头不动", () => {
    expect(stepVolume(5, 1)).toBe(6);
    expect(stepVolume(5, -1)).toBe(4);
    expect(stepVolume(10, 1)).toBe(10);
    expect(stepVolume(0, -1)).toBe(0);
  });

  it("滑块从槽的左头走到右头", () => {
    expect(knobX(0)).toBe(SLIDER.groove);
    expect(knobX(10)).toBe(SLIDER.groove + SLIDER.grooveWidth - SLIDER.knobWidth);
    expect(knobX(5)).toBe(SLIDER.groove + 49);
  });

  it("点在滑条上的位置换成最近的一格，滑块的中间对着它", () => {
    for (let steps = 0; steps <= 10; steps++) {
      expect(volumeAt(knobX(steps) + SLIDER.knobWidth / 2), String(steps)).toBe(steps);
    }
    expect(volumeAt(knobX(4) + 6)).toBe(4);
    expect(volumeAt(knobX(4) + 8)).toBe(5);
  });

  it("点到槽外面（拖出去）停在两头", () => {
    expect(volumeAt(0)).toBe(0);
    expect(volumeAt(-50)).toBe(0);
    expect(volumeAt(139)).toBe(10);
    expect(volumeAt(400)).toBe(10);
  });
});

describe("存在这台设备上", () => {
  const store = new Map<string, string>();
  const storage = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  };
  vi.stubGlobal("localStorage", storage);
  afterEach(() => {
    store.clear();
    vi.restoreAllMocks();
  });
  afterAll(() => {
    vi.unstubAllGlobals();
  });
  // 记在这次页面里的比存着的先读：每个用例用自己的用户。

  it("没存过时两个音量满的、扫描线关着", () => {
    expect(storedSettings("u1")).toEqual({ music: 10, sfx: 10, scanlines: false });
  });

  it("存下的读回来，按用户分开", () => {
    const mine = { music: 3, sfx: 0, scanlines: true };
    keepSettings("u2", mine);
    expect(storedSettings("u2")).toEqual(mine);
    expect(storedSettings("u3")).toEqual(DEFAULT_SETTINGS);
    expect(JSON.parse(store.get("eidolon.barSettings.u2")!)).toEqual(mine);
  });

  it("读不懂的项回默认，读得懂的留着", () => {
    store.set("eidolon.barSettings.u4", JSON.stringify({ music: 11, sfx: 2.5, scanlines: "on" }));
    expect(storedSettings("u4")).toEqual(DEFAULT_SETTINGS);
    store.set("eidolon.barSettings.u5", JSON.stringify({ music: -1, sfx: 4, scanlines: true }));
    expect(storedSettings("u5")).toEqual({ music: 10, sfx: 4, scanlines: true });
  });

  it("坏了的整份回默认", () => {
    store.set("eidolon.barSettings.u6", "{");
    expect(storedSettings("u6")).toEqual(DEFAULT_SETTINGS);
  });

  it("存不进去时这次页面里记着", () => {
    vi.spyOn(storage, "setItem").mockImplementation(() => {
      throw new Error("quota");
    });
    const mine = { music: 1, sfx: 9, scanlines: true };
    keepSettings("u8", mine);
    expect(storedSettings("u8")).toEqual(mine);
  });
});
