// The calendar's arithmetic (.scratch/calendar spec「日历子页」「怎么算」): which days carry what,
// out of three kinds — the characters' birthdays, the producer's own (「我的生日」) and Japan's
// holidays. Birthdays come back every year and are worked out here; holidays are given, a year at
// a time, as the backend lists them. February 29 falls on February 28 in a year without it, as the
// producer's birthday does where she congratulates him. The page only draws what these say.
//
// A date is an ISO day, `YYYY-MM-DD`, in no time zone: the producer's today is `todayIn` his.

import type { Birthday } from "@/lib/api";

/** The kinds of day, in the order the events of one day are listed. */
export const CALENDAR_KINDS = ["character", "producer", "holiday"] as const;

export type CalendarKind = (typeof CALENDAR_KINDS)[number];

/** A holiday as the holidays endpoint gives it: `date` is `YYYY-MM-DD`, `name` the Japanese name. */
export type Holiday = { date: string; name: string };

/** What the calendar is worked out from. `characters` in the idols' order, each with her
 * `birthday` as `MM-DD`; `producerBirthday` null when he has not set one; `holidays` of the years
 * read so far. */
export type CalendarData<C extends { birthday: string }> = {
  characters: readonly C[];
  producerBirthday: Birthday | null;
  holidays: readonly Holiday[];
};

/** One thing on a day: her birthday, the producer's, or a holiday. */
export type CalendarEvent<C> = { kind: "character"; character: C } | { kind: "producer" } | { kind: "holiday"; name: string };

/** The kinds there are: no 「我的生日」 while the producer has no birthday. */
export function calendarKinds(producerBirthday: Birthday | null): CalendarKind[] {
  return CALENDAR_KINDS.filter((kind) => kind !== "producer" || producerBirthday !== null);
}

/** The events on `date` of the kinds `shown`: her birthdays (in the idols' order), then the
 * producer's, then the holiday. */
export function eventsOn<C extends { birthday: string }>(
  date: string,
  data: CalendarData<C>,
  shown: readonly CalendarKind[],
): CalendarEvent<C>[] {
  const year = Number(date.slice(0, 4));
  const events: CalendarEvent<C>[] = [];
  if (shown.includes("character")) {
    for (const character of data.characters) {
      const [month, day] = character.birthday.split("-").map(Number);
      if (birthdayIn(year, month, day) === date) events.push({ kind: "character", character });
    }
  }
  const mine = data.producerBirthday;
  if (shown.includes("producer") && mine && birthdayIn(year, mine.month, mine.day) === date) {
    events.push({ kind: "producer" });
  }
  if (shown.includes("holiday")) {
    for (const holiday of data.holidays) if (holiday.date === date) events.push({ kind: "holiday", name: holiday.name });
  }
  return events;
}

/** The first event on `today` or after, of the kinds `shown`, within a year; null when there is
 * none. Holidays are only found in the years `data` has. */
export function nextEvent<C extends { birthday: string }>(
  today: string,
  data: CalendarData<C>,
  shown: readonly CalendarKind[],
): { date: string; event: CalendarEvent<C> } | null {
  for (let date = today, i = 0; i <= 366; date = addDays(date, 1), i++) {
    const [event] = eventsOn(date, data, shown);
    if (event) return { date, event };
  }
  return null;
}

/** Today's date where the clock reads `now` in `timeZone`. */
export function todayIn(timeZone: string, now: Date): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone }).format(now);
}

/** The month, day and weekday (0 is Sunday) of an ISO day. */
export function partsOf(date: string): { month: number; day: number; weekday: number } {
  const [year, month, day] = date.split("-").map(Number);
  return { month, day, weekday: new Date(Date.UTC(year, month - 1, day)).getUTCDay() };
}

function addDays(date: string, days: number): string {
  const [year, month, day] = date.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day + days)).toISOString().slice(0, 10);
}

/** Where a birthday of `month`/`day` falls in `year`: February 29 on February 28 in a year without it. */
function birthdayIn(year: number, month: number, day: number): string {
  const isLeap = new Date(Date.UTC(year, 1, 29)).getUTCMonth() === 1;
  const fallsOn = month === 2 && day === 29 && !isLeap ? 28 : day;
  return `${year}-${pad(month)}-${pad(fallsOn)}`;
}

function pad(n: number): string {
  return String(n).padStart(2, "0");
}
