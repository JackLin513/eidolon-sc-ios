import { describe, expect, it } from "vitest";

import type { Achievement } from "@/lib/achievements";
import type { CalendarKind } from "@/lib/calendar";
import type { GiftState } from "@/lib/gifts";
import { type CalendarCardContext, playCards, type PlayContext } from "@/lib/playCards";

const BEFORE = "2026-10-20T08:00:00+00:00";
const AFTER = "2026-10-20T09:00:00+00:00";

function giftState(change: Partial<GiftState> = {}): GiftState {
  return {
    open: true,
    draws: 3,
    max_draws: 7,
    backpack: [],
    reset_cards: 0,
    next_draw_at: AFTER,
    resettable: [],
    characters: [],
    daily_tasks: {
      tasks: [
        { id: "one_turn", done: false, progress: 0, goal: 1, draws: 1 },
        { id: "one_gift", done: false, progress: 0, goal: 1, draws: 1 },
        { id: "ten_turns", done: false, progress: 0, goal: 10, draws: 2 },
      ],
      renews_at: AFTER,
    },
    achievements: [],
    rewarded_at: null,
    ...change,
  };
}

function calendar(change: Partial<CalendarCardContext> = {}): CalendarCardContext {
  return {
    today: "2026-10-23",
    data: {
      characters: [
        { name: "櫻木真乃", birthday: "04-25" },
        { name: "樋口円香", birthday: "10-27" },
        { name: "福丸小糸", birthday: "10-27" },
      ],
      producerBirthday: { month: 11, day: 3 },
      holidays: [
        { date: "2026-11-03", name: "文化の日" },
        { date: "2027-01-01", name: "元日" },
      ],
    },
    shown: ["character", "producer", "holiday"],
    ...change,
  };
}

function context(change: Partial<PlayContext> = {}): PlayContext {
  return { state: giftState(), newRewards: false, achievementsSeenAt: null, calendar: calendar(), ...change };
}

/** 合起来的一个成就：第一阶段在 `unlockedAt` 解锁（null 是没解锁）。 */
function achievement(id: string, unlockedAt: string | null, stages = 1): Achievement {
  return {
    id,
    progress: 1,
    stages: Array.from({ length: stages }, (_, i) => ({ goal: i + 1, draws: 1, unlocked_at: i === 0 ? unlockedAt : null })),
  } as Achievement;
}

const ofId = (cards: ReturnType<typeof playCards>, id: string) => cards.find((card) => card.id === id);

describe("玩法页的卡", () => {
  it("好感度和礼物开着时有「礼物」「每日任务与成就」「日历」三张，礼物在上面，各去各的子页", () => {
    const cards = playCards(context());

    expect(cards.map((card) => [card.id, card.name, card.href])).toEqual([
      ["gifts", "礼物", "/play/gifts"],
      ["tasks", "每日任务与成就", "/play/tasks"],
      ["calendar", "日历", "/play/calendar"],
    ]);
  });

  it("没开放时只剩「日历」", () => {
    const cards = playCards(context({ state: giftState({ open: false }) }));

    expect(cards.map((card) => card.id)).toEqual(["calendar"]);
  });

  it("接口还没回来时卡片就在，状态那一行是空的", () => {
    const cards = playCards(context({ state: null, calendar: null }));

    expect(cards.map((card) => [card.id, card.status])).toEqual([
      ["gifts", ""],
      ["tasks", ""],
      ["calendar", ""],
    ]);
  });
});

describe("「礼物」卡的状态", () => {
  const status = (state: Partial<GiftState>) => ofId(playCards(context({ state: giftState(state) })), "gifts")?.status;

  it("背包空着、没有重置卡时只写还有几次抽奖", () => {
    expect(status({ draws: 3 })).toBe("还有 3 次抽奖");
    expect(status({ draws: 0 })).toBe("还有 0 次抽奖");
  });

  it("背包里有东西时加件数，不是种数", () => {
    expect(status({ draws: 3, backpack: [{ gift_id: "cake", count: 2 }, { gift_id: "tea", count: 10 }] })).toBe(
      "还有 3 次抽奖 · 背包 12 件",
    );
  });

  it("有重置卡时再加张数，背包空着时不写背包那一段", () => {
    expect(
      status({ draws: 3, backpack: [{ gift_id: "cake", count: 12 }], reset_cards: 1 }),
    ).toBe("还有 3 次抽奖 · 背包 12 件 · 重置卡 1 张");
    expect(status({ draws: 1, reset_cards: 2 })).toBe("还有 1 次抽奖 · 重置卡 2 张");
  });
});

describe("「每日任务与成就」卡的状态", () => {
  const tasks = (done: number) => ({
    tasks: ["one_turn", "one_gift", "ten_turns"].map((id, i) => ({ id, done: i < done, progress: 0, goal: 1, draws: 1 })),
    renews_at: AFTER,
  });
  const status = (state: Partial<GiftState>, achievementsSeenAt: string | null = null) =>
    ofId(playCards(context({ state: giftState(state), achievementsSeenAt })), "tasks")?.status;

  it("没做完时写今天做完几项", () => {
    expect(status({ daily_tasks: tasks(0) })).toBe("每日任务 今天 0/3");
    expect(status({ daily_tasks: tasks(2) })).toBe("每日任务 今天 2/3");
  });

  it("三项都做完时写今天都做完了", () => {
    expect(status({ daily_tasks: tasks(3) })).toBe("每日任务 今天都做完了");
  });

  it("有新解锁的成就时后面加几个，和带点的行用同一个看过的时刻比", () => {
    const achievements = [achievement("turns", AFTER), achievement("draws", AFTER), achievement("gifts", BEFORE)];

    expect(status({ daily_tasks: tasks(2), achievements }, BEFORE)).toBe("每日任务 今天 2/3 · 成就 2 个新解锁");
    expect(status({ daily_tasks: tasks(3), achievements }, null)).toBe("每日任务 今天都做完了 · 成就 3 个新解锁");
    expect(status({ daily_tasks: tasks(2), achievements }, AFTER)).toBe("每日任务 今天 2/3");
  });
});

describe("卡片名字旁的点", () => {
  it("「礼物」卡的点随新到的抽奖次数，到账看过以后就没有", () => {
    expect(ofId(playCards(context({ newRewards: true })), "gifts")).toMatchObject({
      hasDot: true,
      dotLabel: "有新到的抽奖次数",
    });
    expect(ofId(playCards(context({ newRewards: false })), "gifts")?.hasDot).toBe(false);
  });

  it("接口还没回来时抽奖次数的点照样跟着，状态那一行是空的", () => {
    expect(ofId(playCards(context({ state: null, newRewards: true })), "gifts")).toMatchObject({
      hasDot: true,
      status: "",
    });
  });

  it("「每日任务与成就」卡的点随新解锁的成就，看过以后就没有", () => {
    const state = giftState({ achievements: [achievement("turns", AFTER)] });

    expect(ofId(playCards(context({ state, achievementsSeenAt: BEFORE })), "tasks")).toMatchObject({
      hasDot: true,
      dotLabel: "有新解锁的成就",
    });
    expect(ofId(playCards(context({ state, achievementsSeenAt: AFTER })), "tasks")?.hasDot).toBe(false);
  });

  it("新到的抽奖次数不点亮「每日任务与成就」卡，新解锁的成就也不点亮「礼物」卡", () => {
    const state = giftState({ achievements: [achievement("turns", AFTER)] });
    const cards = playCards(context({ state, newRewards: false, achievementsSeenAt: null }));

    expect(ofId(cards, "gifts")?.hasDot).toBe(false);
    expect(ofId(playCards(context({ newRewards: true })), "tasks")?.hasDot).toBe(false);
  });
});

describe("「日历」卡的状态", () => {
  const status = (change: Partial<CalendarCardContext> = {}) =>
    ofId(playCards(context({ calendar: calendar(change) })), "calendar")?.status;
  const only = (...shown: CalendarKind[]) => ({ shown });

  it("写最近的一件：谁的生日、节假日、我的生日", () => {
    expect(status()).toBe("下一个：10月27日 樋口円香的生日");
    expect(status(only("holiday"))).toBe("下一个：11月3日 文化の日");
    expect(status(only("producer"))).toBe("下一个：11月3日 我的生日");
  });

  it("今天就有时写今天", () => {
    expect(status({ today: "2026-10-27" })).toBe("今天：樋口円香的生日");
  });

  it("三类全筛掉时为空", () => {
    expect(status(only())).toBe("");
  });

  it("好感度和礼物的状态还没回来也有", () => {
    expect(ofId(playCards(context({ state: null })), "calendar")?.status).toBe("下一个：10月27日 樋口円香的生日");
  });
});
