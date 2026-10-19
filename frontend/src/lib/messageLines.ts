// 消息区的一行一行（DESIGN.md「Layout」的消息区）：跨天处的日期条，一条消息（或她的搭话）和它在组里的位置
// （The Bubble Group Rule），改变了好感度的回复、送礼记录后面那行胶囊，以及照片用完时她推掉的
// 那条回复后面那行胶囊。

import { copy } from "@/i18n";
import type { AffinityChange } from "@/lib/affinity";
import { dayOf } from "@/lib/conversationList";
import type { Entry } from "@/lib/conversationLog";

export type Line =
  | { kind: "day"; key: string; label: string }
  | { kind: "entry"; entry: Entry; first: boolean; last: boolean }
  | { kind: "cue"; key: string; change: AffinityChange }
  | { kind: "photos-used-up"; key: string; retryAt: string };

/**
 * 按日期和说话的人把消息排成行：换了一天先放日期条；同一个人连着发、中间没有日期条的算一组。
 * 对话事件自成一行，按它的时间参加跨天判断，也把前后分成两组。她的搭话总是另起一组：它前面那条留着自己的时间。
 * 好感度可用时（`affinityOn`），改变了好感度的回复和送礼记录后面插一行胶囊，它也把前后分成两组；
 * 不可用时存下的变化不显示。照片用完时（这一轮收到了 `photos-used-up`），她那条回复后面再插一行胶囊，
 * 在变化胶囊之后，同样把前后分成两组。
 */
export function linesOf(entries: Entry[], now: Date, affinityOn: boolean): Line[] {
  const days = entries.map((e) => new Date(e.at).toDateString());
  const cueOf = (entry: Entry | undefined) =>
    affinityOn && entry && entry.kind !== "user" ? entry.affinity : null;
  const usedUpOf = (entry: Entry | undefined) => (entry?.kind === "character" ? entry.photosUsedUp : undefined);
  const splitsAfter = (entry: Entry | undefined) => cueOf(entry) !== null || usedUpOf(entry) !== undefined;
  const reachesOut = (entry: Entry | undefined) => entry?.kind === "character" && entry.reachOut === true;
  const lines: Line[] = [];
  entries.forEach((entry, i) => {
    const newDay = i === 0 || days[i] !== days[i - 1];
    if (newDay) lines.push({ kind: "day", key: `day-${days[i]}`, label: dayLabel(new Date(entry.at), now) });
    const previous = entries[i - 1];
    const next = entries[i + 1];
    const cue = cueOf(entry);
    const usedUp = usedUpOf(entry);
    lines.push({
      kind: "entry",
      entry,
      first: newDay || previous.kind !== entry.kind || splitsAfter(previous) || reachesOut(entry),
      last: !next || days[i + 1] !== days[i] || next.kind !== entry.kind || splitsAfter(entry) || reachesOut(next),
    });
    if (cue) lines.push({ kind: "cue", key: `cue-${entry.key}`, change: cue });
    if (usedUp) lines.push({ kind: "photos-used-up", key: `photos-used-up-${entry.key}`, retryAt: usedUp });
  });
  return lines;
}

/** 日期条上的字：今天、昨天，今年写月日，更早写年月日（和列表的写法一样）。 */
function dayLabel(at: Date, now: Date): string {
  const list = copy.conversationList;
  switch (dayOf(at, now)) {
    case "today":
      return copy.conversation.today;
    case "yesterday":
      return list.yesterday;
    case "thisYear":
      return list.monthDay(String(at.getMonth() + 1), String(at.getDate()));
    case "earlier":
      return list.fullDate(String(at.getFullYear()), String(at.getMonth() + 1), String(at.getDate()));
  }
}
