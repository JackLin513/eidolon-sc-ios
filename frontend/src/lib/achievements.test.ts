import { describe, expect, it } from "vitest";

import { achievementRow, completeRow, type Achievement } from "@/lib/achievements";

const AT = "2026-09-25T12:00:00+00:00";

/** 一个成就：门槛 `goals`（第 n 阶段给 n 次），已经进到 `progress`，前 `unlocked` 个阶段解锁了。 */
function achievement(id: string, progress: Achievement["progress"], goals: (number | string)[], unlocked = 0): Achievement {
  return {
    id,
    progress,
    stages: goals.map((goal, i) => ({ goal, draws: i + 1, unlocked_at: i < unlocked ? AT : null })),
  } as Achievement;
}

describe("成就的一行", () => {
  it("回合：名字、阶段点、下一个阶段的进度和它的奖励", () => {
    const row = achievementRow(achievement("turns", 420, [10, 100, 300, 1000, 3000], 3));

    expect(row).toEqual({
      id: "turns",
      name: "和她的回合",
      stages: [true, true, true, false, false],
      isAllUnlocked: false,
      progress: "420 个回合 / 1000 个回合",
      reward: "抽奖 ×4",
    });
  });

  it("一个都没解锁：下一个是第一阶段，抽奖 ×1", () => {
    const row = achievementRow(achievement("gifts", 0, [1, 10, 30, 100]));

    expect(row.stages).toEqual([false, false, false, false]);
    expect(row.progress).toBe("0 件 / 1 件");
    expect(row.reward).toBe("抽奖 ×1");
  });

  it("全部解锁：写「全部解锁」，右边不写奖励", () => {
    const row = achievementRow(achievement("gifts", 140, [1, 10, 30, 100], 4));

    expect(row.isAllUnlocked).toBe(true);
    expect(row.progress).toBe("全部解锁");
    expect(row.reward).toBeNull();
  });

  it("下一个阶段按解锁了几个算，不按进度：门槛调低以后还没解锁的照样是下一个", () => {
    const row = achievementRow(achievement("turns", 120, [10, 100, 300], 1));

    expect(row.progress).toBe("120 个回合 / 100 个回合");
    expect(row.reward).toBe("抽奖 ×2");
  });

  it.each([
    [0, 600, "0 分钟 / 10 分钟"],
    [540, 600, "9 分钟 / 10 分钟"],
    [11520, 18000, "3 小时 12 分 / 5 小时"],
    [7200, 18000, "2 小时 / 5 小时"],
    [3599, 3600, "59 分钟 / 1 小时"],
  ])("通话 %i 秒、下一个 %i 秒：%s", (progress, goal, text) => {
    const row = achievementRow(achievement("call_time", progress, [goal]));

    expect(row.name).toBe("和她通话");
    expect(row.progress).toBe(text);
  });

  it("档位：写「下一个：亲密」，不写进度", () => {
    const row = achievementRow(achievement("tier", "close", ["close", "intimate"], 1));

    expect(row.name).toBe("她的好感度到过");
    expect(row.progress).toBe("下一个：亲密");
    expect(row.reward).toBe("抽奖 ×2");
  });

  it("档位一个都没到过：下一个：亲近", () => {
    expect(achievementRow(achievement("tier", null, ["close", "intimate"])).progress).toBe("下一个：亲近");
  });

  it.each([
    ["characters", "往来过的角色", 5, 10, "5 位 / 10 位"],
    ["intimate_characters", "到过亲密的角色", 0, 1, "0 位 / 1 位"],
    ["days", "来过的天数", 12, 30, "12 天 / 30 天"],
    ["draws", "抽过的奖", 37, 50, "37 次 / 50 次"],
  ])("合起来的 %s：%s，%s", (id, name, progress, goal, text) => {
    const row = achievementRow(achievement(id, progress, [goal]));

    expect(row.name).toBe(name);
    expect(row.progress).toBe(text);
  });

  it("不认识的成就照样列出，名字用 id，进度写数字", () => {
    const row = achievementRow(achievement("photos", 2, [5]));

    expect(row.name).toBe("photos");
    expect(row.progress).toBe("2 / 5");
  });
});

describe("集齐那一行", () => {
  it("没集齐：空圈、「集齐」、「重置卡 ×1」", () => {
    expect(completeRow({ completed_at: null, reset_cards: 1 })).toEqual({
      isComplete: false,
      name: "集齐",
      reward: "重置卡 ×1",
    });
  });

  it("集齐了：勾、「集齐了」、右边不写", () => {
    expect(completeRow({ completed_at: AT, reset_cards: 1 })).toEqual({
      isComplete: true,
      name: "集齐了",
      reward: null,
    });
  });
});
