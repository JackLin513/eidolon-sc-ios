"use client";

import { useState } from "react";

import { MarkedAvatar } from "@/components/app/MarkedAvatar";
import { PlayShell, PlaySubpageHeader } from "@/components/play/PlayShell";
import { useCalendar } from "@/components/play/useCalendar";
import { Button } from "@/components/ui/button";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { copy } from "@/i18n";
import type { Character } from "@/lib/api";
import {
  CALENDAR_KINDS,
  type CalendarCell,
  type CalendarData,
  type CalendarEvent,
  type CalendarKind,
  type CalendarMonth,
  calendarKinds,
  cellLines,
  eventsOn,
  monthCells,
  monthOf,
  partsOf,
  shiftMonth,
} from "@/lib/calendar";
import { playTitle } from "@/lib/playCards";
import { cn } from "@/lib/utils";
import { herVars } from "@/theme/herVars";
import { BirthdayIcon, HolidayIcon, NextMonthIcon, PreviousMonthIcon } from "@/theme/icons";

const t = copy.play.calendar;

/** 手机上一格最多几个记号。 */
const CELL_MARKS = 4;

const FILTER_ICONS = { character: BirthdayIcon, producer: BirthdayIcon, holiday: HolidayIcon } satisfies Record<
  CalendarKind,
  unknown
>;

/**
 * 「日历」子页（`/play/calendar`，DESIGN.md「玩法页」）：页首返回键回玩法页，末端留给日程那一块的月 / 周切换。
 * 内容从上到下是筛选、月视图和点中的那一天的清单（默认今天，制作人时区）。节假日按月视图上的那几年取，
 * 没回来之前先画生日，这一天所在的年没回来、又没有生日时先不说「这一天没有事」。
 * 好感度和礼物没开放时照常有。
 */
export function CalendarSubpage() {
  const [month, setMonth] = useState<CalendarMonth | null>(null);
  const [picked, setPicked] = useState<string | null>(null);
  const { calendar, hasHolidaysOf, keepShown } = useCalendar({
    years: (today) => yearsOn(monthCells(month ?? monthOf(today), today)),
  });
  if (!calendar) {
    return (
      <PlayShell header={<PlaySubpageHeader title={playTitle("calendar")} />}>
        <p className="text-body text-muted-foreground">{copy.play.loading}</p>
      </PlayShell>
    );
  }
  const { today, data, shown } = calendar;
  const kinds = calendarKinds(data.producerBirthday);
  const visible = kinds.filter((kind) => shown.includes(kind));
  const day = picked ?? today;
  const events = eventsOn(day, data, visible);
  return (
    <PlayShell header={<PlaySubpageHeader title={playTitle("calendar")} />}>
      <Filters
        kinds={kinds}
        visible={visible}
        // 没有的那一类（制作人没生日时的「我的生日」）照原样存着。
        onChange={(next) =>
          keepShown(CALENDAR_KINDS.filter((kind) => (kinds.includes(kind) ? next.includes(kind) : shown.includes(kind))))
        }
      />
      <MonthView
        month={month ?? monthOf(today)}
        today={today}
        picked={day}
        data={data}
        visible={visible}
        onMonth={setMonth}
        onPick={setPicked}
        onToday={() => {
          setMonth(null);
          setPicked(null);
        }}
      />
      {visible.length === 0 ? (
        <p className="text-body text-muted-foreground">{t.nothingShown}</p>
      ) : events.length > 0 || hasHolidaysOf(partsOf(day).year) ? (
        <DayEvents date={day} events={events} />
      ) : (
        <p className="text-body text-muted-foreground">{copy.play.loading}</p>
      )}
    </PlayShell>
  );
}

/** 月视图上出现的那几年（首尾补上的天可能落在前后一年）。 */
function yearsOn(cells: CalendarCell[]): number[] {
  return [partsOf(cells[0].date).year, partsOf(cells[cells.length - 1].date).year];
}

/** 「10月27日 周二」。 */
function dayLabel(date: string): string {
  const { month, day, weekday } = partsOf(date);
  return `${t.date(month, day)} ${t.weekdays[weekday]}`;
}

/** 月视图上方的一排筛选：每类一个按钮，按下的（中性 `bg-muted`）是开着的；制作人没生日时没有「我的生日」。 */
function Filters({
  kinds,
  visible,
  onChange,
}: {
  kinds: CalendarKind[];
  visible: CalendarKind[];
  onChange: (visible: CalendarKind[]) => void;
}) {
  return (
    <ToggleGroup
      aria-label={t.filters.label}
      multiple
      variant="outline"
      size="sm"
      className="flex-wrap"
      value={visible}
      onValueChange={(next) => onChange(kinds.filter((kind) => next.includes(kind)))}
    >
      {kinds.map((kind) => {
        const Icon = FILTER_ICONS[kind];
        return (
          <ToggleGroupItem key={kind} value={kind}>
            <Icon aria-hidden />
            {t.filters[kind]}
          </ToggleGroupItem>
        );
      })}
    </ToggleGroup>
  );
}

/**
 * 月视图：标题「2026年10月」，两边上个月、下个月，不在当月时后面一个「今天」；周一到周日七列，非当月的格子淡下去、
 * 照常显示事。今天的日期数字一个中性圆底，点中的格子铺中性 `bg-muted`。电脑（≥ 768px）上一格最多三行字，
 * 手机上一排 6px 的记号。
 */
function MonthView({
  month,
  today,
  picked,
  data,
  visible,
  onMonth,
  onPick,
  onToday,
}: {
  month: CalendarMonth;
  today: string;
  picked: string;
  data: CalendarData<Character>;
  visible: CalendarKind[];
  onMonth: (month: CalendarMonth) => void;
  onPick: (date: string) => void;
  onToday: () => void;
}) {
  const thisMonth = monthOf(today);
  const isThisMonth = month.year === thisMonth.year && month.month === thisMonth.month;
  const title = t.month(month.year, month.month);
  return (
    <section className="flex flex-col gap-3">
      <div className="flex items-center gap-1">
        <Button variant="ghost" size="icon-sm" aria-label={t.previousMonth} onClick={() => onMonth(shiftMonth(month, -1))}>
          <PreviousMonthIcon />
        </Button>
        <h2 className="min-w-28 text-center text-header tabular-nums">{title}</h2>
        <Button variant="ghost" size="icon-sm" aria-label={t.nextMonth} onClick={() => onMonth(shiftMonth(month, 1))}>
          <NextMonthIcon />
        </Button>
        {!isThisMonth && (
          <Button variant="ghost" size="sm" onClick={onToday}>
            {t.today}
          </Button>
        )}
      </div>
      <div role="group" aria-label={title} className="grid grid-cols-7 gap-px overflow-hidden rounded-lg border bg-border">
        {t.weekHeads.map((head) => (
          <span key={head} aria-hidden className="bg-background py-1 text-center text-meta text-muted-foreground">
            {head}
          </span>
        ))}
        {monthCells(month, today).map((cell) => (
          <DayCell
            key={cell.date}
            cell={cell}
            events={eventsOn(cell.date, data, visible)}
            isPicked={cell.date === picked}
            onPick={() => onPick(cell.date)}
          />
        ))}
      </div>
    </section>
  );
}

function DayCell({
  cell,
  events,
  isPicked,
  onPick,
}: {
  cell: CalendarCell;
  events: CalendarEvent<Character>[];
  isPicked: boolean;
  onPick: () => void;
}) {
  const { events: lines, more } = cellLines(events);
  return (
    <button
      type="button"
      aria-label={t.cell(dayLabel(cell.date), events.length)}
      aria-pressed={isPicked}
      aria-current={cell.isToday ? "date" : undefined}
      onClick={onPick}
      className={cn(
        "flex min-h-14 min-w-0 flex-col bg-background p-1 text-left outline-none hover:bg-muted/60 focus-visible:z-10 focus-visible:ring-3 focus-visible:ring-ring/50 md:min-h-24",
        isPicked && "bg-muted hover:bg-muted",
      )}
    >
      <span className={cn("flex min-w-0 flex-col gap-1", !cell.isInMonth && "opacity-50")}>
        <span
          className={cn(
            "flex size-6 items-center justify-center rounded-full text-subtitle tabular-nums",
            cell.isToday && "bg-foreground text-background",
          )}
        >
          {partsOf(cell.date).day}
        </span>
        <span aria-hidden className="flex gap-0.5 px-0.5 md:hidden">
          {events.slice(0, CELL_MARKS).map((event) => (
            <span
              key={eventKey(event)}
              style={event.kind === "character" ? herVars(event.character.color) : undefined}
              className={cn("size-1.5 rounded-full", event.kind === "character" ? "bg-her-mark" : "bg-muted-foreground")}
            />
          ))}
        </span>
        <span aria-hidden className="flex min-w-0 flex-col gap-0.5 max-md:hidden">
          {lines.map((event) => (
            <span key={eventKey(event)} className="flex min-w-0 items-center gap-1 text-meta">
              <EventIcon event={event} />
              <span className="truncate">{eventText(event)}</span>
            </span>
          ))}
          {more > 0 && <span className="text-meta text-muted-foreground">{t.more(more)}</span>}
        </span>
      </span>
    </button>
  );
}

/** 16px 的图标：角色生日是她颜色的蛋糕（每一项单独注入一次她的颜色），我的生日的蛋糕和节假日的旗子不上色。 */
function EventIcon({ event }: { event: CalendarEvent<Character> }) {
  if (event.kind === "character") {
    return (
      <span style={herVars(event.character.color)} className="flex shrink-0">
        <BirthdayIcon aria-hidden className="size-4 text-her-mark" />
      </span>
    );
  }
  const Icon = event.kind === "holiday" ? HolidayIcon : BirthdayIcon;
  return <Icon aria-hidden className="size-4 shrink-0 text-muted-foreground" />;
}

function eventText(event: CalendarEvent<Character>): string {
  if (event.kind === "character") return event.character.name;
  return event.kind === "holiday" ? event.name : t.mine;
}

/**
 * 这一天的清单：Subtitle 字号 muted 的日期（「10月27日 周二」），下面一行一件。角色生日是她 24px 的头像、显示名和
 * Meta 字号 muted 的「生日」，前面一个她颜色的蛋糕（每一项单独注入一次她的颜色）；节假日是旗子加名字，我的生日是
 * 蛋糕加「我的生日」，都不上色。什么也没有时一句 muted 的「这一天没有事」。
 */
function DayEvents({ date, events }: { date: string; events: CalendarEvent<Character>[] }) {
  return (
    <section className="flex flex-col gap-3">
      <h2 className="text-subtitle text-muted-foreground">{dayLabel(date)}</h2>
      {events.length === 0 ? (
        <p className="text-body text-muted-foreground">{t.noEvents}</p>
      ) : (
        <ul className="flex flex-col gap-3">
          {events.map((event) => (
            <li key={eventKey(event)} className="flex min-w-0 items-center gap-2 text-body">
              <EventRow event={event} />
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function EventRow({ event }: { event: CalendarEvent<Character> }) {
  if (event.kind === "character") {
    const { character } = event;
    return (
      <>
        <MarkedAvatar name={character.name} src={character.avatar_url} size="sm" />
        <span className="truncate">{character.name}</span>
        <span style={herVars(character.color)} className="flex shrink-0 items-center gap-1">
          <BirthdayIcon aria-hidden className="size-3 text-her-mark" />
          <span className="text-meta text-muted-foreground">{t.birthday}</span>
        </span>
      </>
    );
  }
  return (
    <>
      <span className="flex size-6 shrink-0 items-center justify-center">
        <EventIcon event={event} />
      </span>
      <span className="truncate">{eventText(event)}</span>
    </>
  );
}

function eventKey(event: CalendarEvent<Character>): string {
  if (event.kind === "character") return `character:${event.character.id}`;
  return event.kind === "holiday" ? `holiday:${event.name}` : "producer";
}
