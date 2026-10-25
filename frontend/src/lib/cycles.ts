// 周期子页和玩法页「周期」卡读的东西（.scratch/cycle-page spec「接口」「周期子页（版式 D）」，GLOSSARY.md「周期」「推算」）：
// 用户给每位角色记下的经期，和后端从这些记录现算的推算。推算只在后端算，这里只照它画月历上的记号、头像条的筛选、
// 她那一句话、点中那一天的一条、记录列表和弹窗的几处规则。这里没有、也从不读她真实的周期。

import { copy } from "@/i18n";
import { api, ApiError, json } from "@/lib/api";
import { addDays, type CalendarCell, type CalendarMonth, monthCells, partsOf, shiftMonth } from "@/lib/calendar";
import { matchesSearch, type Searchable } from "@/lib/characterSearch";

const t = copy.play.cycles;

/** 变淡的原因：只记一次、长短不一、可能漏记、这次可能还没记下。 */
export type CycleReason = "once" | "irregular" | "missed" | "late";

/** 一段经期：第一天（`YYYY-MM-DD` 的日历日）起的几天。 */
export type CyclePeriod = { first_day: string; days: number };

/** 记下的一次经期：第一天是用户那时时区下的日历日。 */
export type CycleRecord = CyclePeriod & { id: string };

/** 今天在哪：记下的经期第几天、推算的经期、推算的经前，或者都不是。 */
export type CycleToday = { kind: "recorded"; day: number } | { kind: "estimated" } | { kind: "premenstrual" } | null;

export type CycleEstimate = {
  cycle: number;
  period: number;
  /** 按 once、irregular、missed、late 排；空的就是不变淡。 */
  reasons: CycleReason[];
  /** 推算的 3 次经期；经前是每次第一天之前的 5 天。 */
  periods: CyclePeriod[];
  /** 过去的估算平均差，能比两个周期以后才有。 */
  off_by: number | null;
  today: CycleToday;
};

/** 一位角色的记录（按第一天从早到晚）和推算（没记过的为 null）。 */
export type Her = { character_id: string; records: CycleRecord[]; estimate: CycleEstimate | null };

/** `GET /api/cycles`：两个开关任一关着时只说没开；开着时是今天和全部角色，顺序照角色名单。 */
export type CyclesView = { enabled: false } | { enabled: true; today: string; characters: Her[] };

/** 推算的经前：每次推算的经期第一天之前几天。 */
const PREMENSTRUAL_DAYS = 5;

export const FEWEST_DAYS = 1;
export const MOST_DAYS = 10;

/** 没记过时弹窗里的天数。 */
const FIRST_DAYS = 5;

/** 记录列表只露几次。 */
const RECORDS_SHOWN = 3;

const CONFLICT = 409;

export async function getCycles(): Promise<CyclesView> {
  return json(await api("/api/cycles"));
}

export async function addCycleRecord(characterId: string, record: CyclePeriod): Promise<Her> {
  return json(await api(`/api/cycles/${encodeURIComponent(characterId)}/records`, writeRequest("POST", record)));
}

export async function changeCycleRecord(id: string, record: CyclePeriod): Promise<Her> {
  return json(await api(`/api/cycles/records/${encodeURIComponent(id)}`, writeRequest("PUT", record)));
}

export async function deleteCycleRecord(id: string): Promise<Her> {
  return json(await api(`/api/cycles/records/${encodeURIComponent(id)}`, { method: "DELETE" }));
}

function writeRequest(method: string, record: CyclePeriod): RequestInit {
  return { method, headers: { "content-type": "application/json" }, body: JSON.stringify(record) };
}

/** 写的时候服务器说周期关着（部署者或用户刚关掉）。 */
export function isCyclesOff(e: unknown): boolean {
  return e instanceof ApiError && e.status === CONFLICT;
}

/** 换掉一位的记录和推算（记、改、删以后用返回的）。 */
export function withHer(view: CyclesView, her: Her): CyclesView {
  if (!view.enabled) return view;
  return { ...view, characters: view.characters.map((h) => (h.character_id === her.character_id ? her : h)) };
}

export type CycleDayKind = "recorded" | "estimated" | "premenstrual";

/** 月历一格的记号：记下的盖过推算的；变淡的只有推算的；`isPremenstrualStart` 是每段经前的第一天（电脑上写「经前」）。 */
export type CycleMark = { kind: CycleDayKind | null; isFaded: boolean; isPremenstrualStart: boolean };

function isWithin(date: string, period: CyclePeriod): boolean {
  return date >= period.first_day && date < addDays(period.first_day, period.days);
}

/** 这一天落在哪条记录里。 */
export function recordOn(date: string, records: readonly CycleRecord[]): CycleRecord | undefined {
  return records.find((r) => isWithin(date, r));
}

function kindOn(date: string, her: Her): CycleDayKind | null {
  if (recordOn(date, her.records)) return "recorded";
  const periods = her.estimate?.periods ?? [];
  if (periods.some((p) => isWithin(date, p))) return "estimated";
  if (periods.some((p) => date >= addDays(p.first_day, -PREMENSTRUAL_DAYS) && date < p.first_day)) return "premenstrual";
  return null;
}

function markOn(date: string, her: Her): CycleMark {
  const kind = kindOn(date, her);
  const isFaded = kind !== null && kind !== "recorded" && (her.estimate?.reasons.length ?? 0) > 0;
  const isPremenstrualStart = kind === "premenstrual" && kindOn(addDays(date, -1), her) !== "premenstrual";
  return { kind, isFaded, isPremenstrualStart };
}

/** 月历上 `month` 的每一格（周一在前）和它的记号。 */
export function monthMarks(month: CalendarMonth, today: string, her: Her): (CalendarCell & { mark: CycleMark })[] {
  return monthCells(month, today).map((cell) => ({ ...cell, mark: markOn(cell.date, her) }));
}

/** 头像条的四类筛选：全部、记过的、推算在经前经期的、还没记过的。 */
export const CYCLE_FILTERS = ["all", "recorded", "now", "unrecorded"] as const;

export type CycleFilter = (typeof CYCLE_FILTERS)[number];

function isKept(filter: CycleFilter, her: Her | undefined): boolean {
  const recorded = (her?.records.length ?? 0) > 0;
  if (filter === "recorded") return recorded;
  if (filter === "unrecorded") return !recorded;
  if (filter === "now") return (her?.estimate?.today ?? null) !== null;
  return true;
}

/** 每类有几位。 */
export function filterCounts(hers: readonly Her[]): Record<CycleFilter, number> {
  return Object.fromEntries(
    CYCLE_FILTERS.map((filter) => [filter, hers.filter((her) => isKept(filter, her)).length]),
  ) as Record<CycleFilter, number>;
}

/** 头像条里的人，照名单的顺序：搜索时只看搜索、不看筛选；选中的她一直留着。 */
export function stripOf<C extends Searchable & { id: string }>(
  characters: readonly C[],
  hers: readonly Her[],
  { filter, query, picked }: { filter: CycleFilter; query: string; picked: string | null },
): C[] {
  const byId = new Map(hers.map((her) => [her.character_id, her]));
  const isSearching = query.trim() !== "";
  return characters.filter(
    (c) => c.id === picked || (isSearching ? matchesSearch(c, query) : isKept(filter, byId.get(c.id))),
  );
}

/** 「10月27日」。 */
export function monthDay(date: string): string {
  const { month, day } = partsOf(date);
  return copy.play.calendar.date(month, day);
}

function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(to) - Date.parse(from)) / 86_400_000);
}

/** 她那一块顶上的一句话。 */
export function herLine(her: Her, today: string): string {
  const { estimate } = her;
  if (!estimate) return t.line.none;
  const where = estimate.today;
  if (where?.kind === "recorded") return t.line.recorded(where.day);
  if (where?.kind === "estimated") return t.line.estimated;
  const next = estimate.periods.find((p) => p.first_day > today) ?? estimate.periods[0];
  if (where?.kind === "premenstrual") return t.line.premenstrual(monthDay(next.first_day));
  if (estimate.reasons.includes("late")) return t.line.late(monthDay(estimate.periods[0].first_day));
  return t.line.next(
    monthDay(next.first_day),
    daysBetween(today, next.first_day),
    monthDay(addDays(next.first_day, -PREMENSTRUAL_DAYS)),
  );
}

/** 点中那一天的一条右端：以这天为第一天记一次、不能记未来、改它所在的那次。 */
export type DayAction = { kind: "first" } | { kind: "future" } | { kind: "edit"; record: CycleRecord };

/** 点中那一天的一条：没点时一句提示；点了写日期和它是什么，右端一个键。 */
export function dayBar(date: string | null, her: Her, today: string): { text: string; action: DayAction | null } {
  if (date === null) return { text: t.day.prompt, action: null };
  const kind = kindOn(date, her);
  const text = kind ? [monthDay(date), t.kinds[kind]].join(copy.play.separator) : monthDay(date);
  const record = recordOn(date, her.records);
  if (record) return { text, action: { kind: "edit", record } };
  return { text, action: { kind: date > today ? "future" : "first" } };
}

export type RecordRow = { record: CycleRecord; text: string };

/** 右栏的「记过的经期」：新的在上，每行「5 天 · 隔 29 天」（最早一条没有隔）；只露最近 3 次（只多 1 次时全露），
 * `toggle` 是下面「展开全部 n 次 / 收起」的字，不用折时为 null。 */
export function shownRecords(
  records: readonly CycleRecord[],
  isExpanded: boolean,
): { rows: RecordRow[]; toggle: string | null } {
  const rows = records
    .map((record, i) => ({
      record,
      text: t.records.row(record.days, i > 0 ? daysBetween(records[i - 1].first_day, record.first_day) : null),
    }))
    .reverse();
  if (rows.length <= RECORDS_SHOWN + 1) return { rows, toggle: null };
  return isExpanded
    ? { rows, toggle: t.records.less }
    : { rows: rows.slice(0, RECORDS_SHOWN), toggle: t.records.all(rows.length) };
}

/** 记新的一次时弹窗里的天数：推算的经期天数，没记过为 5。 */
export function defaultDays(estimate: CycleEstimate | null): number {
  return estimate?.period ?? FIRST_DAYS;
}

/** −/+ 夹在 1–10 天。 */
export function clampDays(days: number): number {
  return Math.min(MOST_DAYS, Math.max(FEWEST_DAYS, days));
}

/** 小月历上这一天能不能选：今天以后不能。 */
export function isPickable(date: string, today: string): boolean {
  return date <= today;
}

/** 小月历能不能翻到下个月：下个月的第一天已经在今天以后时不能。 */
export function canShowNextMonth(month: CalendarMonth, today: string): boolean {
  const next = shiftMonth(month, 1);
  return isPickable(`${next.year}-${String(next.month).padStart(2, "0")}-01`, today);
}

/** 「2026年10月25日 周日」：不用原生日期框，它的年月日顺序跟着浏览器语言走。 */
export function fullDate(date: string): string {
  const { year, month, day, weekday } = partsOf(date);
  return t.dialog.fullDate(year, month, day, copy.play.calendar.weekdays[weekday]);
}

/** 地址里 `?who=`（lib/schedule 的 `calendarWho` 读出来的）选中的她：没带、带了不认识的 id 时选名单上的第一位；
 * 名单空着时没有。 */
export function cyclesWho(who: string | null, characterIds: readonly string[]): string | null {
  return who !== null && characterIds.includes(who) ? who : (characterIds[0] ?? null);
}

/** 推算的下一次经期离今天最近的那位（玩法页卡上的「最近」）：下一次第一天不早于今天里最早的；都过了日子时取最早的。 */
export function soonest(hers: readonly Her[], today: string): { characterId: string; firstDay: string } | null {
  const next = hers.flatMap((her) =>
    her.estimate ? [{ characterId: her.character_id, firstDay: her.estimate.periods[0].first_day }] : [],
  );
  const coming = next.filter((n) => n.firstDay >= today);
  const pool = coming.length > 0 ? coming : next;
  return pool.reduce<(typeof pool)[number] | null>((best, n) => (best && best.firstDay <= n.firstDay ? best : n), null);
}
