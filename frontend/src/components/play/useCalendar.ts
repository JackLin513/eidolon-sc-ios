"use client";

import { useCallback, useEffect, useState } from "react";

import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { type Character, getProfile, type ProducerProfile } from "@/lib/api";
import { type CalendarKind, type CalendarView, type Holiday, todayIn } from "@/lib/calendar";
import { keepShownKinds, shownKinds } from "@/lib/calendarFilter";
import { getHolidays } from "@/lib/holidays";
import { producerTimezone } from "@/lib/timezone";

const NO_PROFILE: Pick<ProducerProfile, "timezone" | "birthday"> = { timezone: null, birthday: null };

/**
 * 玩法页第一级的「日历」卡和日历子页共用的数据（.scratch/calendar spec「数据」）：角色用外壳已经载入的那一份
 * （带生日、头像按外观换好），制作人档案读一次（生日和时区；读不到当作没生日、用浏览器的时区），节假日按年取
 * （`years` 从制作人的今天给出要哪几年；取过的留着，翻回来不再等，lib/holidays）。开着的几类读这台设备上记着的，
 * `keepShown` 改了就存下、重画。
 * 角色、档案和登录的用户都读到之前 `calendar` 是 null；`years` 里的节假日没都回来之前里面先没有它们，`holidaysRead` 为假。
 */
export function useCalendar({ years }: { years: (today: string) => readonly number[] }) {
  const { account, characters } = useDirectory();
  const [profile, setProfile] = useState<Pick<ProducerProfile, "timezone" | "birthday"> | null>(null);
  const [holidays, setHolidays] = useState<ReadonlyMap<number, Holiday[]>>(new Map());
  const [kept, setKept] = useState<{ userId: string; kinds: CalendarKind[] } | null>(null);

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
  const wanted = today ? [...new Set(years(today))] : [];
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

  const userId = account?.id;
  const keepShown = useCallback(
    (kinds: readonly CalendarKind[]) => {
      if (!userId) return;
      keepShownKinds(userId, kinds);
      setKept({ userId, kinds: shownKinds(userId) });
    },
    [userId],
  );

  const calendar: CalendarView<Character> | null =
    today && profile && characters && account
      ? {
          today,
          data: {
            characters,
            producerBirthday: profile.birthday,
            holidays: [...holidays.keys()].sort().flatMap((year) => holidays.get(year) ?? []),
          },
          shown: kept?.userId === account.id ? kept.kinds : shownKinds(account.id),
        }
      : null;
  const holidaysRead = wanted.length > 0 && wanted.every((year) => holidays.has(year));
  return { calendar, holidaysRead, keepShown };
}
