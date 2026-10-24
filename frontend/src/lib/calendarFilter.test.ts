import { afterEach, describe, expect, it, vi } from "vitest";

import { keepShownKinds, shownKinds } from "@/lib/calendarFilter";

const ALL = ["character", "producer", "holiday", "schedule"];

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
  it("没存过时全开", () => {
    storage();

    expect(shownKinds("user-1")).toEqual(ALL);
  });

  it("按用户分开存关掉的几类，读回来是开着的几类，按类别的顺序", () => {
    const items = storage();

    keepShownKinds("user-1", ["holiday", "character"]);
    keepShownKinds("user-2", []);

    expect(shownKinds("user-1")).toEqual(["character", "holiday"]);
    expect(shownKinds("user-2")).toEqual([]);
    expect(shownKinds("user-3")).toEqual(ALL);
    expect(items.get("eidolon.calendarKinds.user-1")).toBe(JSON.stringify({ hidden: ["producer", "schedule"] }));
  });

  it("老用户存的开着的几类读出来日程是开的", () => {
    storage({
      "eidolon.calendarKinds.old-1": JSON.stringify(["character", "holiday"]),
      "eidolon.calendarKinds.old-2": JSON.stringify([]),
    });

    expect(shownKinds("old-1")).toEqual(["character", "holiday", "schedule"]);
    expect(shownKinds("old-2")).toEqual(["schedule"]);
  });

  it("存的不是一组类别、或者里面有认不得的时回到全开", () => {
    storage({
      "eidolon.calendarKinds.broken-1": "{not json",
      "eidolon.calendarKinds.broken-2": JSON.stringify({ holiday: true }),
      "eidolon.calendarKinds.odd": JSON.stringify(["holiday", "birthdays", 3]),
      "eidolon.calendarKinds.odd-hidden": JSON.stringify({ hidden: ["holiday", "birthdays"] }),
    });

    for (const user of ["broken-1", "broken-2", "odd", "odd-hidden"]) expect(shownKinds(user), user).toEqual(ALL);
  });

  it("存不进去时只在这次页面里记着", () => {
    const unreachable = () => {
      throw new DOMException("denied", "SecurityError");
    };
    vi.stubGlobal("localStorage", { getItem: unreachable, setItem: unreachable, removeItem: unreachable });

    expect(shownKinds("private-1")).toEqual(ALL);
    expect(() => keepShownKinds("private-1", ["producer"])).not.toThrow();
    expect(shownKinds("private-1")).toEqual(["producer"]);
  });
});
