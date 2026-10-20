// 每日任务（GLOSSARY.md「每日任务」）：礼物页抽奖台下面那一节怎么显示。每天同样几项，做完一项自动得到抽奖次数，
// 每天北京时间 0 点换新；哪几项、门槛和奖励都由后端给，这里只管写成那一节的几行字。

import { copy } from "@/i18n";

/** 一项任务：做完没有、做到哪了（不超过目标）、目标、做完给几次抽奖。 */
export type DailyTask = { id: string; done: boolean; progress: number; goal: number; draws: number };

/** 读礼物状态接口给的今天的每日任务，和换新的时刻（ISO，下一个北京时间 0 点）。 */
export type DailyTasks = { tasks: DailyTask[]; renews_at: string };

/** 那一节的一行：名字、打勾没有、没做完且目标不止 1 时的进度（「3/10」）、右边的「抽奖 ×1」。 */
export type DailyTaskRow = { id: string; name: string; isDone: boolean; progress: string | null; reward: string };

/** 那一节：标题旁做完几项（「1/3」）、右边换新的时刻、每项一行。 */
export type DailyTasksView = { count: string; renews: string; rows: DailyTaskRow[] };

/** 每日任务那一节怎么显示；`next` 是 `nextDrawText` 写好的换新时刻。后端给了不认识的一项也照样列出，名字用 id。 */
export function dailyTasksView(daily: DailyTasks, next: string): DailyTasksView {
  const t = copy.gifts.dailyTasks;
  const done = daily.tasks.filter((task) => task.done).length;
  return {
    count: t.of(done, daily.tasks.length),
    renews: t.renews(next),
    rows: daily.tasks.map((task) => ({
      id: task.id,
      name: t.names[task.id] ?? task.id,
      isDone: task.done,
      progress: !task.done && task.goal > 1 ? t.of(task.progress, task.goal) : null,
      reward: t.reward(task.draws),
    })),
  };
}

/** 到账里做完的那几项（`done` 是 id）当场记成做完，不等重读礼物状态。 */
export function withDone(daily: DailyTasks, done: readonly string[]): DailyTasks {
  return {
    ...daily,
    tasks: daily.tasks.map((task) => (done.includes(task.id) ? { ...task, done: true, progress: task.goal } : task)),
  };
}
