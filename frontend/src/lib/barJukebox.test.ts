import { afterEach, describe, expect, it, vi } from "vitest";

import type { BarAudio } from "@/lib/barAudio";
import {
  clearSlot,
  defaultSlots,
  hasJukebox,
  isReady,
  jukeboxPage,
  jukeboxPages,
  keepJukebox,
  nextSlot,
  previousSlot,
  slotAfter,
  toggleMode,
  pickTrack,
  storedJukebox,
  swapSlots,
} from "@/lib/barJukebox";

const track = (id: number) => ({ id, file: `${String(id).padStart(3, "0")}_t.ogg`, title: `T${id}` });
/** 13 首在桶里，默认曲单是前 12 首倒过来。 */
const audio: BarAudio = {
  tracks: Array.from({ length: 13 }, (_, i) => track(i + 1)),
  playlist: [12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1],
  sfx: ["door"],
};
const full = [12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1];

describe("默认的 12 首", () => {
  it("是清单的默认曲单", () => {
    expect(defaultSlots(audio)).toEqual(full);
  });

  it("桶里缺的几首空着", () => {
    expect(defaultSlots({ ...audio, playlist: [12, 11] })).toEqual([12, 11, ...Array(10).fill(null)]);
  });
});

describe("选曲界面的 12 个槽", () => {
  it("点曲名放进第一个空槽，可以重复", () => {
    const slots = [5, null, 7, null, ...Array(8).fill(1)];
    expect(pickTrack(slots, 5)).toEqual([5, 5, 7, null, ...Array(8).fill(1)]);
  });

  it("满了点曲名什么都不变", () => {
    expect(pickTrack(full, 13)).toEqual(full);
  });

  it("点两个槽对调", () => {
    expect(swapSlots(full, 0, 11)).toEqual([1, ...full.slice(1, 11), 12]);
  });

  it("清掉一个，后面不补位", () => {
    expect(clearSlot(full, 1)).toEqual([12, null, ...full.slice(2)]);
  });

  it("12 个槽满了才 Ready!", () => {
    expect(isReady(full)).toBe(true);
    expect(isReady(clearSlot(full, 5))).toBe(false);
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
  // 记在这次页面里的比存着的先读：每个用例用自己的用户。
  const fresh = { slots: full, isPaused: false, mode: "order" };

  it("没存过时是默认的 12 首、在放、顺序放", () => {
    expect(storedJukebox("u1", audio)).toEqual(fresh);
  });

  it("存下的选择和播放器状态读回来，按用户分开", () => {
    const mine = { slots: [13, ...full.slice(1)], isPaused: true, mode: "shuffle" as const };
    keepJukebox("u1", mine);
    expect(storedJukebox("u1", audio)).toEqual(mine);
    expect(storedJukebox("u2", audio)).toEqual(fresh);
  });

  it("读不懂的槽回默认：编号不在表里、不是 12 个、不是数组", () => {
    for (const slots of [[99, ...full.slice(1)], full.slice(1), "x", [null, ...full.slice(1)]]) {
      store.set("eidolon.barJukebox.u4", JSON.stringify({ slots, isPaused: true, mode: "loop" }));
      expect(storedJukebox("u4", audio), JSON.stringify(slots)).toEqual({ ...fresh, isPaused: true, mode: "loop" });
    }
  });

  it("读不懂的播放器状态回默认，坏了的整份回默认", () => {
    store.set("eidolon.barJukebox.u5", JSON.stringify({ slots: full, isPaused: "yes", mode: "both" }));
    expect(storedJukebox("u5", audio)).toEqual(fresh);
    store.set("eidolon.barJukebox.u6", "{");
    expect(storedJukebox("u6", audio)).toEqual(fresh);
  });

  it("存不进去时这次页面里记着", () => {
    vi.spyOn(storage, "setItem").mockImplementation(() => {
      throw new Error("quota");
    });
    const mine = { slots: full, isPaused: true, mode: "loop" as const };
    keepJukebox("u3", mine);
    expect(storedJukebox("u3", audio)).toEqual(mine);
  });
});

describe("小播放器", () => {
  /** 随机数：总是给 `x`。 */
  const always = (x: number) => () => x;

  it("顺序放：一首完了放下一个槽，第 12 首完了从头", () => {
    expect(slotAfter("order", 0, always(0))).toBe(1);
    expect(slotAfter("order", 11, always(0))).toBe(0);
  });

  it("单曲循环：一首完了再放这一首；下一首照样往下", () => {
    expect(slotAfter("loop", 4, always(0))).toBe(4);
    expect(nextSlot("loop", 4, always(0))).toBe(5);
  });

  it("随机：完了、点下一首都随便放一个别的槽", () => {
    expect(slotAfter("shuffle", 0, always(0))).toBe(1);
    expect(slotAfter("shuffle", 3, always(0.2))).toBe(2);
    expect(nextSlot("shuffle", 3, always(0.3))).toBe(4);
    expect(nextSlot("shuffle", 11, always(0.999))).toBe(10);
  });

  it("上一首往回，第 1 首往回是第 12 首", () => {
    expect(previousSlot(5)).toBe(4);
    expect(previousSlot(0)).toBe(11);
  });

  it("下一首到头从第 1 首", () => {
    expect(nextSlot("order", 11, always(0))).toBe(0);
  });

  it("随机和单曲循环互斥：开一个关另一个，再点关掉", () => {
    expect(toggleMode("order", "shuffle")).toBe("shuffle");
    expect(toggleMode("loop", "shuffle")).toBe("shuffle");
    expect(toggleMode("shuffle", "loop")).toBe("loop");
    expect(toggleMode("shuffle", "shuffle")).toBe("order");
    expect(toggleMode("loop", "loop")).toBe("order");
  });
});

describe("没有可用的音频时", () => {
  it("整块不可用；有一首就能用", () => {
    expect(hasJukebox({ tracks: [], playlist: [], sfx: [] })).toBe(false);
    expect(hasJukebox({ tracks: [], playlist: [], sfx: ["door"] })).toBe(false);
    expect(hasJukebox(audio)).toBe(true);
  });
});

describe("左边的曲名", () => {
  it("5 首一页，页数照实算，最后一页剩几首是几首", () => {
    expect(jukeboxPages(audio.tracks)).toBe(3);
    expect(jukeboxPage(audio.tracks, 0).map((t) => t.id)).toEqual([1, 2, 3, 4, 5]);
    expect(jukeboxPage(audio.tracks, 2).map((t) => t.id)).toEqual([11, 12, 13]);
  });

  it("原版的 59 首是 12 页", () => {
    expect(jukeboxPages(Array.from({ length: 59 }, (_, i) => track(i)))).toBe(12);
  });
});
