// 成就（GLOSSARY.md「成就」）：她的对话页面板和礼物页那一小节里，每一行怎么写。一个成就分几个阶段，按序号解锁，
// 第 n 阶段给 n 次抽奖；她按角色算的阶段全部解锁叫集齐，另给重置卡。门槛、奖励、解锁了哪几个都由后端给，这里只管
// 写成一行：名字、阶段点、只写下一个阶段的进度、下一阶段的奖励。档位只有档位名，不给好感度的数值。

import type { Tier } from "@/lib/affinity";
import type { Rewarded } from "@/lib/rewards";
import { copy } from "@/i18n";

/** 一个阶段：门槛（档位类是档位名）、解锁时给几次抽奖、解锁时刻（ISO，没解锁是 null）。 */
export type AchievementStage = { goal: number | Tier; draws: number; unlocked_at: string | null };

/** 一个成就：id、累计进度（通话是秒，档位类是到过的最高档位、一个没到过是 null）、按序号排的阶段。 */
export type Achievement = { id: string; progress: number | Tier | null; stages: AchievementStage[] };

/** 集齐那一行：集齐的时刻（ISO，没集齐是 null）、集齐给几张重置卡。 */
export type Complete = { completed_at: string | null; reset_cards: number };

/** 读她的成就接口给的：她按角色算的四个，和集齐那一行。开关关着时接口给 null。 */
export type HerAchievements = { achievements: Achievement[]; complete: Complete };

/** 这次到账里解锁的一个阶段：哪个成就、哪位角色（合起来的是 null）、第几阶段、给了几次抽奖。 */
export type UnlockedStage = Rewarded["achievements"][number];

/** 一行：名字、阶段点（解锁的为 true）、全部解锁没有、下一个阶段的进度（全部解锁时写「全部解锁」）、下一阶段的奖励（全部解锁是 null）。 */
export type AchievementRow = {
  id: string;
  name: string;
  stages: boolean[];
  isAllUnlocked: boolean;
  progress: string;
  reward: string | null;
};

/** 集齐那一行：集齐了没有、「集齐」或「集齐了」、没集齐时右边的「重置卡 ×n」。 */
export type CompleteRow = { isComplete: boolean; name: string; reward: string | null };

/**
 * 一个成就那一行怎么写。下一个阶段是第一个没解锁的（门槛调低以后进度可能已经过了它，到下一次往来才解锁）。
 * 后端给了不认识的成就也照样列出，名字用 id，进度只写数字。
 */
export function achievementRow(achievement: Achievement): AchievementRow {
  const t = copy.achievements;
  const stages = achievement.stages.map((s) => s.unlocked_at !== null);
  const next = achievement.stages.find((s) => s.unlocked_at === null);
  return {
    id: achievement.id,
    name: t.names[achievement.id] ?? achievement.id,
    stages,
    isAllUnlocked: next === undefined,
    progress: next === undefined ? t.allUnlocked : progressText(achievement.id, achievement.progress, next.goal),
    reward: next === undefined ? null : t.draws(next.draws),
  };
}

/** 集齐那一行怎么写。 */
export function completeRow(complete: Complete): CompleteRow {
  const t = copy.achievements;
  const isComplete = complete.completed_at !== null;
  return {
    isComplete,
    name: isComplete ? t.completed : t.complete,
    reward: isComplete ? null : t.resetCards(complete.reset_cards),
  };
}

/** 进度文字：「420 个回合 / 1000 个回合」；档位类只写「下一个：亲密」。 */
function progressText(id: string, progress: Achievement["progress"], goal: AchievementStage["goal"]): string {
  const t = copy.achievements;
  if (typeof goal === "string") return t.nextTier(copy.conversation.affinity.tiers[goal]);
  const amount = typeof progress === "number" ? progress : 0;
  const unit = id === "call_time" ? duration : (t.units[id] ?? String);
  return `${unit(amount)} / ${unit(goal)}`;
}

/** 通话时长（秒）：不到一小时写「n 分钟」，否则「3 小时 12 分」，整小时只写「5 小时」。 */
function duration(seconds: number): string {
  const t = copy.achievements.duration;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return t.minutes(minutes);
  const rest = minutes % 60;
  return rest ? t.hoursMinutes(Math.floor(minutes / 60), rest) : t.hours(minutes / 60);
}
