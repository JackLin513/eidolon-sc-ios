// 朋友圈页的时间线（GLOSSARY.md「朋友圈」「动态」，DESIGN.md「朋友圈页」）：一行底下 Meta 字号的那一行怎么写。
// 时间线只有 30 天内的动态，所以不写日期，只写离现在多久。

import {
  Cloud,
  CloudFog,
  CloudLightning,
  CloudRain,
  CloudSnow,
  CloudSun,
  type LucideIcon,
  Sun,
} from "lucide-react";

import { copy } from "@/i18n";
import type { Moment, WeatherKind } from "@/lib/api";

const t = copy.moments;

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

/** 一条动态露出（`posted_at`）离 `now` 多久：不到 1 分钟「刚刚」（钟慢了、露出在将来的也是），不到 1 小时「N 分钟前」，
 * 不到 24 小时「N 小时前」；再早按本地日历算差几天，差 1 天「昨天」，其余「N 天前」。 */
export function postedText(postedAt: string, now: Date): string {
  const at = new Date(postedAt);
  const elapsed = now.getTime() - at.getTime();
  if (elapsed < MINUTE) return t.justNow;
  if (elapsed < HOUR) return t.minutesAgo(Math.floor(elapsed / MINUTE));
  if (elapsed < 24 * HOUR) return t.hoursAgo(Math.floor(elapsed / HOUR));
  const days = calendarDaysBetween(at, now);
  return days <= 1 ? t.yesterday : t.daysAgo(days);
}

/** `at` 那天到 `now` 那天隔了几天（本地日历，夏令时换算不影响）。 */
function calendarDaysBetween(at: Date, now: Date): number {
  const dayOf = (d: Date) => Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()) / (24 * HOUR);
  return dayOf(now) - dayOf(at);
}

/** 天气每一档的图标。 */
const WEATHER_ICONS: Record<WeatherKind, LucideIcon> = {
  clear: Sun,
  cloudy: CloudSun,
  overcast: Cloud,
  fog: CloudFog,
  rain: CloudRain,
  snow: CloudSnow,
  thunder: CloudLightning,
};

/** Meta 一行的一段：时间，带地图链接的地名，或天气（图标、读屏读的档位名和整数气温）。 */
export type MetaPart =
  | { kind: "time"; text: string }
  | { kind: "place"; text: string; href: string }
  | { kind: "weather"; text: string; icon: LucideIcon; label: string };

/** Meta 一行从左到右的几段，中间用分隔点连：时间、地名（点开看地图）、天气。没有的部分不出现，分隔点跟着省掉。 */
export function metaParts(moment: Moment, now: Date): MetaPart[] {
  const parts: MetaPart[] = [{ kind: "time", text: postedText(moment.posted_at, now) }];
  if (moment.place) parts.push({ kind: "place", text: moment.place.name, href: moment.place.map });
  if (moment.weather) {
    const { kind, temperature } = moment.weather;
    parts.push({ kind: "weather", text: `${temperature}°`, icon: WEATHER_ICONS[kind], label: t.weather[kind] });
  }
  return parts;
}
