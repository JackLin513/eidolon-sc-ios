import { describe, expect, it } from "vitest";

import { postedText } from "@/lib/moments";

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
