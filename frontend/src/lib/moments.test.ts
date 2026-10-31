import { Cloud, CloudFog, CloudLightning, CloudRain, CloudSnow, CloudSun, Sun } from "lucide-react";
import { describe, expect, it } from "vitest";

import type { Moment, WeatherKind } from "@/lib/api";
import { metaParts, postedText } from "@/lib/moments";

/** 本地时间的某一刻（测试不依赖所在时区）。 */
function local(day: number, hour: number, minute = 0, second = 0): Date {
  return new Date(2026, 9, day, hour, minute, second);
}

const now = local(31, 12, 0);

describe("时间线一行的时间", () => {
  it("不到 1 分钟写「刚刚」，露出在将来（钟慢了）也是", () => {
    expect(postedText(local(31, 11, 59, 30).toISOString(), now)).toBe("刚刚");
    expect(postedText(now.toISOString(), now)).toBe("刚刚");
    expect(postedText(local(31, 12, 5).toISOString(), now)).toBe("刚刚");
  });

  it("不到 1 小时写几分钟前，向下取整", () => {
    expect(postedText(local(31, 11, 59).toISOString(), now)).toBe("1 分钟前");
    expect(postedText(local(31, 11, 0, 30).toISOString(), now)).toBe("59 分钟前");
  });

  it("不到 24 小时写几小时前，跨过半夜也是", () => {
    expect(postedText(local(31, 11, 0).toISOString(), now)).toBe("1 小时前");
    expect(postedText(local(30, 12, 0, 1).toISOString(), now)).toBe("23 小时前");
    expect(postedText(local(30, 23, 0).toISOString(), local(31, 1, 0))).toBe("2 小时前");
  });

  it("再早按日历算：前一天写「昨天」，更早写几天前", () => {
    expect(postedText(local(30, 12, 0).toISOString(), now)).toBe("昨天");
    expect(postedText(local(30, 0, 0).toISOString(), now)).toBe("昨天");
    expect(postedText(local(29, 23, 0).toISOString(), now)).toBe("2 天前");
    expect(postedText(local(1, 12, 0).toISOString(), now)).toBe("30 天前");
  });
});

describe("时间线一行的 Meta", () => {
  const moment: Moment = {
    id: 1,
    character_id: "mano",
    ja: "池のボート",
    zh: "池塘的小船",
    image: null,
    place: null,
    weather: null,
    posted_at: local(31, 11, 0).toISOString(),
  };
  const map = "https://www.openstreetmap.org/?mlat=35.6997&mlon=139.5731#map=17/35.6997/139.5731";

  it("有地名时是「时间 · 地名」，地名带地图链接", () => {
    const parts = metaParts({ ...moment, place: { name: "井の頭恩賜公園", map } }, now);
    expect(parts).toEqual([
      { kind: "time", text: "1 小时前" },
      { kind: "place", text: "井の頭恩賜公園", href: map },
    ]);
  });

  it("没有地名时只有时间，分隔点也省掉", () => {
    expect(metaParts(moment, now)).toEqual([{ kind: "time", text: "1 小时前" }]);
  });

  it("有天气时排在最后，是图标加整数气温：「时间 · 地名 · ☀ 18°」", () => {
    const parts = metaParts(
      { ...moment, place: { name: "井の頭恩賜公園", map }, weather: { kind: "clear", temperature: 18 } },
      now,
    );
    expect(parts).toEqual([
      { kind: "time", text: "1 小时前" },
      { kind: "place", text: "井の頭恩賜公園", href: map },
      { kind: "weather", text: "18°", icon: Sun, label: "晴" },
    ]);
  });

  it("没有地名、有天气时是「时间 · 天气」，零下照写负号", () => {
    expect(metaParts({ ...moment, weather: { kind: "snow", temperature: -2 } }, now)).toEqual([
      { kind: "time", text: "1 小时前" },
      { kind: "weather", text: "-2°", icon: CloudSnow, label: "雪" },
    ]);
  });

  it("有地名、没有天气时是「时间 · 地名」", () => {
    expect(metaParts({ ...moment, place: { name: "井の頭恩賜公園", map } }, now).map((p) => p.kind)).toEqual([
      "time",
      "place",
    ]);
  });

  it.each<[WeatherKind, unknown, string]>([
    ["clear", Sun, "晴"],
    ["cloudy", CloudSun, "多云"],
    ["overcast", Cloud, "阴"],
    ["fog", CloudFog, "雾"],
    ["rain", CloudRain, "雨"],
    ["snow", CloudSnow, "雪"],
    ["thunder", CloudLightning, "雷雨"],
  ])("天气「%s」用它自己的图标", (kind, icon, label) => {
    const weather = metaParts({ ...moment, weather: { kind, temperature: 10 } }, now).at(-1);
    expect(weather).toEqual({ kind: "weather", text: "10°", icon, label });
  });
});
