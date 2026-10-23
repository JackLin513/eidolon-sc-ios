"use client";

import { MarkedAvatar } from "@/components/app/MarkedAvatar";
import { PlayShell, PlaySubpageHeader } from "@/components/play/PlayShell";
import { useCalendar } from "@/components/play/useCalendar";
import { copy } from "@/i18n";
import type { Character } from "@/lib/api";
import { type CalendarEvent, eventsOn, partsOf } from "@/lib/calendar";
import { playTitle } from "@/lib/playCards";
import { herVars } from "@/theme/herVars";
import { BirthdayIcon, HolidayIcon } from "@/theme/icons";

const t = copy.play.calendar;

/** 子页这一块只看今天：节假日取今年的。 */
const THIS_YEAR = [0];

/**
 * 「日历」子页（`/play/calendar`，DESIGN.md「玩法页」）：页首返回键回玩法页，末端留给日程那一块的月 / 周切换；
 * 内容是这一天的清单，现在只有今天（制作人时区）。按这台设备上开着的几类列；节假日没回来之前先列生日。
 * 好感度和礼物没开放时照常有。
 */
export function CalendarSubpage() {
  const { today, data, shown } = useCalendar({ years: THIS_YEAR });
  return (
    <PlayShell header={<PlaySubpageHeader title={playTitle("calendar")} />}>
      {today && data && shown ? (
        <DayEvents date={today} events={eventsOn(today, data, shown)} />
      ) : (
        <p className="text-body text-muted-foreground">{copy.play.loading}</p>
      )}
    </PlayShell>
  );
}

/**
 * 这一天的清单：Subtitle 字号 muted 的日期（「10月27日 周二」），下面一行一件。角色生日是她 24px 的头像、显示名和
 * Meta 字号 muted 的「生日」，前面一个她颜色的蛋糕（每一项单独注入一次她的颜色）；节假日是旗子加名字，我的生日是
 * 蛋糕加「我的生日」，都不上色。什么也没有时一句 muted 的「这一天没有事」。
 */
function DayEvents({ date, events }: { date: string; events: CalendarEvent<Character>[] }) {
  const { month, day, weekday } = partsOf(date);
  return (
    <section className="flex flex-col gap-3">
      <h2 className="text-subtitle text-muted-foreground">
        {t.date(month, day)} {t.weekdays[weekday]}
      </h2>
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
  const Icon = event.kind === "holiday" ? HolidayIcon : BirthdayIcon;
  return (
    <>
      <span className="flex size-6 shrink-0 items-center justify-center">
        <Icon aria-hidden className="size-4 text-muted-foreground" />
      </span>
      <span className="truncate">{event.kind === "holiday" ? event.name : t.mine}</span>
    </>
  );
}

function eventKey(event: CalendarEvent<Character>): string {
  if (event.kind === "character") return `character:${event.character.id}`;
  return event.kind === "holiday" ? `holiday:${event.name}` : "producer";
}
