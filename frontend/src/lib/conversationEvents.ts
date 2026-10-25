// 对话事件（GLOSSARY.md「对话事件」）给用户看的那句话：消息区的分隔线和列表的「最后一句」共用。

import { copy } from "@/i18n";
import type { ConversationEvent, EventKind } from "@/lib/api";

/** 她不太舒服了从哪天起：这次经期的第一天（ISO 日期），比记下那天早几天。 */
export type Unwell = { firstDay: string; daysAgo: number };

/** 一条对话事件要说的：哪种，送礼记录的礼物名（`gift`，别的事件没有），她不太舒服了的从哪天起（`unwell`）。 */
export type EventShown = { event: EventKind; gift: string | null; unwell?: Unwell };

/** 接口给的一条事件里她不太舒服了从哪天起；别的事件没有。 */
export function unwellOf(event: Pick<ConversationEvent, "first_day" | "days_ago">): Unwell | undefined {
  const { first_day: firstDay, days_ago: daysAgo } = event;
  return firstDay !== undefined && daysAgo !== undefined ? { firstDay, daysAgo } : undefined;
}

/** 这条事件给用户看的那句话，`name` 是她的名字。 */
export function eventText({ event, gift, unwell }: EventShown, name: string): string {
  return copy.conversation.events[event](name, unwell ? since(unwell) : (gift ?? ""));
}

/** 「从…起」中间那几个字：早 0、1、2 天是今天、昨天、前天，再早是那天的日期。 */
function since({ firstDay, daysAgo }: Unwell): string {
  const t = copy.conversation.unwellSince;
  const word = t.days[daysAgo];
  if (word !== undefined) return word;
  const [, month, day] = firstDay.split("-").map(Number);
  return t.date(month, day);
}
