// 日历的筛选（.scratch/calendar spec「筛选」）：开着哪几类，只存在这台设备上，在 localStorage 里按用户分开存
// （键为 eidolon.calendarKinds.<用户 ID>），值是关掉的几类 `{ hidden: [...] }`，所以以后加的类别默认开着。
// 加「日程」以前存的是开着的几类（一个数组）：读到这种旧值时，那时有的三类里没在数组里的算关着，其余开着。
// 没存过、读不到或数据坏了（不是一组类别、里面有认不得的）当作全开；存不进去
// （隐私模式等）时不抛错，只在这次页面里记着。制作人没生日时「我的生日」这一类由 lib/calendar 的
// `calendarKinds` 略去，这里照存。

import { CALENDAR_KINDS, type CalendarKind } from "@/lib/calendar";

/** 加「日程」以前的几类：旧值是其中开着的。 */
const BEFORE_SCHEDULE: readonly CalendarKind[] = ["character", "producer", "holiday"];

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
  const hidden = hiddenIn(stored);
  return CALENDAR_KINDS.filter((kind) => !hidden.includes(kind));
}

/** 存着的值里关掉的几类；认不得时一类也不关。 */
function hiddenIn(stored: unknown): readonly unknown[] {
  const isKinds = (value: unknown): value is unknown[] =>
    Array.isArray(value) && value.every((item) => CALENDAR_KINDS.some((kind) => kind === item));
  if (isKinds(stored)) return BEFORE_SCHEDULE.filter((kind) => !stored.includes(kind));
  const hidden = typeof stored === "object" && stored !== null ? (stored as { hidden?: unknown }).hidden : undefined;
  return isKinds(hidden) ? hidden : [];
}

/** 存下这位用户开着的几类。 */
export function keepShownKinds(userId: string, kinds: readonly CalendarKind[]): void {
  const ordered = CALENDAR_KINDS.filter((kind) => kinds.includes(kind));
  try {
    const hidden = CALENDAR_KINDS.filter((kind) => !kinds.includes(kind));
    localStorage.setItem(storageKey(userId), JSON.stringify({ hidden }));
  } catch {
    // 存储不可用：只在这次页面里记着。
    keptThisPage.set(userId, ordered);
  }
}
