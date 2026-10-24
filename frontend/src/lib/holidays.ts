// Japan's holidays as the backend lists them (.scratch/calendar spec「节假日」), a year at a time.
// A year read is kept for as long as the page is open, so the play page and the calendar read each
// year once; one that failed is read again next time.

import { api, json } from "@/lib/api";
import type { Holiday } from "@/lib/calendar";

const read = new Map<number, Promise<Holiday[]>>();

/** The holidays of `year`, by date; none for a year the backend cannot work out. */
export function getHolidays(year: number): Promise<Holiday[]> {
  let holidays = read.get(year);
  if (!holidays) {
    holidays = api(`/api/calendar/holidays?${new URLSearchParams({ year: String(year) })}`).then((res) =>
      json<Holiday[]>(res),
    );
    holidays.catch(() => read.delete(year));
    read.set(year, holidays);
  }
  return holidays;
}
