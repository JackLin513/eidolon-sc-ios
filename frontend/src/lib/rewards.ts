// 到账：做完一项每日任务（GLOSSARY.md「每日任务」），抽奖次数自动给到用户（成就的奖励也走这里）。回合的 `done`、
// 送礼的返回带着「这次到账」；礼物状态带着最近一次到账的时刻。导航栏和 dock 的「礼物」上那个点意思是「有新到的
// 抽奖次数」：开关开着、最近一次到账晚于这台设备上看过的，就亮。
//
// 看过只记在这台设备上，照公告已读（lib/announcements）的做法：localStorage 里按用户分开存
// （eidolon.rewardsSeen.<用户 id>），存的是看过的最近一次到账时刻。读不出或者不是时刻的，算没看过；
// 这台设备上还没存过时，任何到账都算没看过。存不进去（无痕浏览）时只在这次页面里记着。

/**
 * 这次到账了什么：抽奖次数、重置卡张数、做完了哪几项每日任务（id）、解锁了哪些成就阶段（lib/achievements；合起来的
 * 角色是 null）、集齐了哪几位角色，和这位用户最近一次到账的时刻（ISO，服务器时间）。
 */
export type Rewarded = {
  draws: number;
  reset_cards: number;
  daily_tasks: string[];
  achievements: { achievement: string; character_id: string | null; stage: number; draws: number }[];
  completed: { character_id: string; reset_cards: number }[];
  rewarded_at: string;
};

function seenKey(userId: string): string {
  return `eidolon.rewardsSeen.${userId}`;
}

/** 存不进去时，这次页面里记着的。 */
const seenThisPage = new Map<string, string>();

/** 这位用户在这台设备上看过的最近一次到账时刻；没看过为 null。 */
export function rewardsSeenUpTo(userId: string): string | null {
  let stored: unknown = null;
  try {
    stored = JSON.parse(localStorage.getItem(seenKey(userId)) ?? "null");
  } catch {
    // 读不出或者坏了：算没看过，这次页面里记着的除外。
  }
  const kept = typeof stored === "string" && !Number.isNaN(Date.parse(stored)) ? stored : null;
  return later(kept, seenThisPage.get(userId) ?? null);
}

/** 记下这位用户看过了 `at` 为止的到账；别的标签页已经记下更晚的，就留着那个。 */
export function keepRewardsSeenUpTo(userId: string, at: string): void {
  const seen = later(rewardsSeenUpTo(userId), at) ?? at;
  seenThisPage.set(userId, seen);
  try {
    localStorage.setItem(seenKey(userId), JSON.stringify(seen));
  } catch {
    // 存不进去：只在这次页面里记着。
  }
}

/** 「礼物」上的点亮不亮：开关开着（`isOpen`），而且最近一次到账（`rewardedAt`）晚于看过的（`seenAt`）。 */
export function hasNewRewards({
  isOpen,
  rewardedAt,
  seenAt,
}: {
  isOpen: boolean;
  rewardedAt: string | null;
  seenAt: string | null;
}): boolean {
  if (!isOpen || rewardedAt === null) return false;
  return seenAt === null || Date.parse(rewardedAt) > Date.parse(seenAt);
}

/** 两个时刻里晚的那个；null 比哪个都早。 */
export function later(a: string | null, b: string | null): string | null {
  if (a === null) return b;
  if (b === null) return a;
  return Date.parse(b) > Date.parse(a) ? b : a;
}
