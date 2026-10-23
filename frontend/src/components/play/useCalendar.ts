"use client";

import { useEffect, useState } from "react";

import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { type Character, getProfile, type ProducerProfile } from "@/lib/api";
import { type CalendarData, type CalendarKind, type Holiday, todayIn } from "@/lib/calendar";
import { shownKinds } from "@/lib/calendarFilter";
import { getHolidays } from "@/lib/holidays";
import { producerTimezone } from "@/lib/timezone";

const NO_PROFILE: Pick<ProducerProfile, "timezone" | "birthday"> = { timezone: null, birthday: null };

/**
 * 玩法页第一级的「日历」卡和日历子页共用的数据（.scratch/calendar spec「数据」）：角色用外壳已经载入的那一份
 * （带生日、头像按外观换好），制作人档案读一次（生日和时区；读不到当作没生日、用浏览器的时区），节假日按年取
 * （`years` 是相对今天所在那一年的几年，0 是今年；取过的留着，lib/holidays）。开着的几类读这台设备上记着的。
 * 角色和档案读到之前 `today`、`data` 都是 null；节假日没回来之前 `data` 里先没有它们，`holidaysRead` 为假。
 */
export function useCalendar({ years }: { years: readonly number[] }) {
  const { account, characters } = useDirectory();
  const [profile, setProfile] = useState<Pick<ProducerProfile, "timezone" | "birthday"> | null>(null);
  const [holidays, setHolidays] = useState<ReadonlyMap<number, Holiday[]>>(new Map());

  useEffect(() => {
    let current = true;
    getProfile().then(
      (p) => current && setProfile(p),
      () => current && setProfile(NO_PROFILE),
    );
    return () => {
      current = false;
    };
  }, []);

  const today = profile ? todayIn(producerTimezone(profile.timezone), new Date()) : null;
  const thisYear = today ? Number(today.slice(0, 4)) : null;
  const wanted = thisYear === null ? [] : years.map((offset) => thisYear + offset);
  const wantedKey = wanted.join(",");

  useEffect(() => {
    if (!wantedKey) return;
    let current = true;
    for (const year of wantedKey.split(",").map(Number)) {
      // 取不到的那一年当作没有节假日，生日照画。
      getHolidays(year).then(
        (list) => current && setHolidays((read) => new Map(read).set(year, list)),
        () => current && setHolidays((read) => new Map(read).set(year, [])),
      );
    }
    return () => {
      current = false;
    };
  }, [wantedKey]);

  const data: CalendarData<Character> | null =
    profile && characters
      ? {
          characters,
          producerBirthday: profile.birthday,
          holidays: [...holidays.keys()].sort().flatMap((year) => holidays.get(year) ?? []),
        }
      : null;
  const shown: readonly CalendarKind[] | null = account ? shownKinds(account.id) : null;
  const holidaysRead = wanted.length > 0 && wanted.every((year) => holidays.has(year));
  return { today, data, shown, holidaysRead };
}
