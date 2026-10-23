import { afterEach, describe, expect, it, vi } from "vitest";

import { keepShownKinds, shownKinds } from "@/lib/calendarFilter";

/** 这台浏览器的 localStorage，放在内存里。 */
function storage(initial: Record<string, string> = {}) {
  const items = new Map(Object.entries(initial));
  vi.stubGlobal("localStorage", {
    getItem: (key: string) => items.get(key) ?? null,
    setItem: (key: string, value: string) => void items.set(key, value),
    removeItem: (key: string) => void items.delete(key),
  });
  return items;
}

afterEach(() => vi.unstubAllGlobals());

describe("日历的筛选记在本机", () => {
  it("没存过时三类全开", () => {
    storage();

    expect(shownKinds("user-1")).toEqual(["character", "producer", "holiday"]);
  });

  it("按用户分开存，读回来是存的那几类，按类别的顺序", () => {
    const items = storage();

    keepShownKinds("user-1", ["holiday", "character"]);
    keepShownKinds("user-2", []);

    expect(shownKinds("user-1")).toEqual(["character", "holiday"]);
    expect(shownKinds("user-2")).toEqual([]);
    expect(shownKinds("user-3")).toEqual(["character", "producer", "holiday"]);
    expect(items.get("eidolon.calendarKinds.user-1")).toBe(JSON.stringify(["character", "holiday"]));
  });

  it("存的不是几类时回到全开，认不得的类别略过", () => {
    storage({
      "eidolon.calendarKinds.broken-1": "{not json",
      "eidolon.calendarKinds.broken-2": JSON.stringify({ holiday: true }),
      "eidolon.calendarKinds.broken-3": JSON.stringify("holiday"),
      "eidolon.calendarKinds.odd": JSON.stringify(["holiday", "schedule", 3]),
    });

    expect(shownKinds("broken-1")).toEqual(["character", "producer", "holiday"]);
    expect(shownKinds("broken-2")).toEqual(["character", "producer", "holiday"]);
    expect(shownKinds("broken-3")).toEqual(["character", "producer", "holiday"]);
    expect(shownKinds("odd")).toEqual(["holiday"]);
  });

  it("存不进去时只在这次页面里记着", () => {
    const unreachable = () => {
      throw new DOMException("denied", "SecurityError");
    };
    vi.stubGlobal("localStorage", { getItem: unreachable, setItem: unreachable, removeItem: unreachable });

    expect(shownKinds("private-1")).toEqual(["character", "producer", "holiday"]);
    expect(() => keepShownKinds("private-1", ["producer"])).not.toThrow();
    expect(shownKinds("private-1")).toEqual(["producer"]);
  });
});
