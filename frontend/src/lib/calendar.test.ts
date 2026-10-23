import { describe, expect, it } from "vitest";

import { calendarKinds, type CalendarData, type CalendarKind, eventsOn, nextEvent, todayIn } from "@/lib/calendar";

type Idol = { id: string; name: string; birthday: string };

const MANO: Idol = { id: "mano", name: "櫻木真乃", birthday: "04-25" };
const MADOKA: Idol = { id: "madoka", name: "樋口円香", birthday: "10-27" };
const KOITO: Idol = { id: "koito", name: "福丸小糸", birthday: "10-27" };
const LEAP: Idol = { id: "leap", name: "閏年子", birthday: "02-29" };

const ALL: CalendarKind[] = ["character", "producer", "holiday"];

function data(change: Partial<CalendarData<Idol>> = {}): CalendarData<Idol> {
  return {
    characters: [MANO, MADOKA, KOITO],
    producerBirthday: { month: 11, day: 3 },
    holidays: [
      { date: "2026-11-03", name: "文化の日" },
      { date: "2026-11-23", name: "勤労感謝の日" },
      { date: "2027-01-01", name: "元日" },
    ],
    ...change,
  };
}

/** 这一天的事，一件写成一个词：角色写 id，我的生日写「me」，节假日写名字。 */
const on = (date: string, d = data(), shown: CalendarKind[] = ALL) =>
  eventsOn(date, d, shown).map((e) => (e.kind === "character" ? e.character.id : e.kind === "producer" ? "me" : e.name));

describe("某一天的事", () => {
  it("没事的日子什么都没有", () => {
    expect(on("2026-10-26")).toEqual([]);
  });

  it("两位同一天生日都列出来，按偶像顺序", () => {
    expect(on("2026-10-27")).toEqual(["madoka", "koito"]);
    expect(on("2026-10-27", data({ characters: [KOITO, MADOKA] }))).toEqual(["koito", "madoka"]);
  });

  it("角色生日、我的生日、节假日碰在一天时按这个顺序", () => {
    const d = data({ characters: [{ ...MANO, birthday: "11-03" }] });

    expect(on("2026-11-03", d)).toEqual(["mano", "me", "文化の日"]);
  });

  it("生日每年都在，节假日只在给的那一天", () => {
    expect(on("2031-04-25")).toEqual(["mano"]);
    expect(on("2027-11-03")).toEqual(["me"]);
  });

  it("2 月 29 日的生日在没有 29 日的年份落在 28 日，闰年照旧", () => {
    const d = data({ characters: [LEAP], producerBirthday: { month: 2, day: 29 } });

    expect(on("2027-02-28", d)).toEqual(["leap", "me"]);
    expect(on("2028-02-28", d)).toEqual([]);
    expect(on("2028-02-29", d)).toEqual(["leap", "me"]);
  });

  it("制作人没生日时没有我的生日", () => {
    expect(on("2026-11-03", data({ producerBirthday: null }))).toEqual(["文化の日"]);
  });

  it("只列开着的几类", () => {
    const d = data({ characters: [{ ...MANO, birthday: "11-03" }] });

    expect(on("2026-11-03", d, ["holiday"])).toEqual(["文化の日"]);
    expect(on("2026-11-03", d, ["character", "producer"])).toEqual(["mano", "me"]);
    expect(on("2026-11-03", d, [])).toEqual([]);
  });
});

describe("有哪几类", () => {
  it("三类；制作人没生日时没有我的生日", () => {
    expect(calendarKinds({ month: 1, day: 1 })).toEqual(["character", "producer", "holiday"]);
    expect(calendarKinds(null)).toEqual(["character", "holiday"]);
  });
});

describe("下一个", () => {
  const next = (today: string, d = data(), shown: CalendarKind[] = ALL) => {
    const found = nextEvent(today, d, shown);
    if (!found) return null;
    const { date, event } = found;
    return [date, event.kind === "character" ? event.character.id : event.kind === "producer" ? "me" : event.name];
  };

  it("找今天以后最近的一件", () => {
    expect(next("2026-10-23")).toEqual(["2026-10-27", "madoka"]);
    expect(next("2026-10-28")).toEqual(["2026-11-03", "me"]);
  });

  it("今天就有时是今天的", () => {
    expect(next("2026-10-27")).toEqual(["2026-10-27", "madoka"]);
  });

  it("同一天几件取排在前的", () => {
    expect(next("2026-10-28", data(), ["holiday"])).toEqual(["2026-11-03", "文化の日"]);
  });

  it("跨年能找到明年的", () => {
    expect(next("2026-11-24", data(), ["holiday"])).toEqual(["2027-01-01", "元日"]);
    expect(next("2026-11-24", data(), ["character"])).toEqual(["2027-04-25", "mano"]);
  });

  it("全筛掉、或者什么都没有时没有", () => {
    expect(next("2026-10-23", data(), [])).toBeNull();
    expect(next("2026-10-23", data({ producerBirthday: null }), ["producer"])).toBeNull();
    expect(next("2026-11-24", data({ characters: [], producerBirthday: null, holidays: [] }))).toBeNull();
  });
});

describe("今天", () => {
  it("按给的时区算", () => {
    const at = new Date("2026-10-26T15:30:00Z");

    expect(todayIn("Asia/Tokyo", at)).toBe("2026-10-27");
    expect(todayIn("Asia/Shanghai", at)).toBe("2026-10-26");
  });
});
