// 日历的筛选（.scratch/calendar spec「筛选」）：开着哪几类，只存在这台设备上，在 localStorage 里按用户分开存
// （键为 eidolon.calendarKinds.<用户 ID>），值是开着的几类（空的是全关）。没存过、读不到或数据坏了（不是一组类别、里面有认不得的）当作全开；存不进去
// （隐私模式等）时不抛错，只在这次页面里记着。制作人没生日时「我的生日」这一类由 lib/calendar 的
// `calendarKinds` 略去，这里照存。

import { CALENDAR_KINDS, type CalendarKind } from "@/lib/calendar";

function storageKey(userId: string): string {
  return `eidolon.calendarKinds.${userId}`;
}

/** 存不进去时，这次页面里记着的。 */
const keptThisPage = new Map<string, CalendarKind[]>();

/** 这位用户在这台设备上开着的几类，按类别的顺序。 */
export function shownKinds(userId: string): CalendarKind[] {
  const kept = keptThisPage.get(userId);
  if (kept) return kept;
  let stored: unknown;
  try {
    stored = JSON.parse(localStorage.getItem(storageKey(userId)) ?? "null");
  } catch {
    stored = null;
  }
  const isKind = (value: unknown) => CALENDAR_KINDS.some((kind) => kind === value);
  if (!Array.isArray(stored) || !stored.every(isKind)) return [...CALENDAR_KINDS];
  return CALENDAR_KINDS.filter((kind) => stored.includes(kind));
}

/** 存下这位用户开着的几类。 */
export function keepShownKinds(userId: string, kinds: readonly CalendarKind[]): void {
  const ordered = CALENDAR_KINDS.filter((kind) => kinds.includes(kind));
  try {
    localStorage.setItem(storageKey(userId), JSON.stringify(ordered));
  } catch {
    // 存储不可用：只在这次页面里记着。
    keptThisPage.set(userId, ordered);
  }
}
