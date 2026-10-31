import { describe, expect, it } from "vitest";

import {
  LEAD_IN,
  STALL_MS,
  finishesAt,
  hasUnread,
  letterDay,
  partsOf,
  showsLetterButton,
  signsAt,
  tick,
  timerClock,
  voiceClock,
  written,
  type LetterSummary,
} from "@/lib/letter";

/** 每块的起止，四舍五入到毫秒，免得浮点数的尾巴。 */
function spans(parts: { start: number; end: number }[]): number[][] {
  return parts.map((p) => [p.start, p.end].map((t) => Math.round(t * 1000) / 1000));
}

const letter = {
  salutation: "Pさんへ",
  paragraphs: [
    { ja: "ありがとう。", zh: "谢谢。" },
    { ja: "またね", zh: "再见" },
  ],
};

function summary(read: boolean): LetterSummary {
  return { id: 1, character_id: "mano", occasions: ["close"], day: "2026-10-31", read, popped: false };
}

describe("时间轴", () => {
  it("没有语音时按字数估：一个字 0.15 秒，一块至少 1 秒；抬头后停 0.6 秒，段与段之间停 0.9 秒", () => {
    const parts = partsOf(letter);
    expect(spans(parts)).toEqual([
      [1.2, 2.2], // 4 个字，不到 1 秒算 1 秒
      [2.8, 3.8], // 6 个字，0.9 秒，算 1 秒
      [4.7, 5.7],
    ]);
  });

  it("给了每块的实际时长就照它排", () => {
    const parts = partsOf(letter, [2, 3, 1.5]);
    expect(spans(parts)).toEqual([
      [1.2, 3.2],
      [3.8, 6.8],
      [7.7, 9.2],
    ]);
  });

  it("时长和块数对不上时当作没有，按字数估", () => {
    expect(partsOf(letter, [2, 3])).toEqual(partsOf(letter));
  });

  it("每个字的时刻在这一块之内、单调不减，标点后面多停", () => {
    const [, first] = partsOf(letter, [2, 3, 1.5]);
    expect(first.at[0]).toBe(first.start);
    expect(first.at.every((t, i) => i === 0 || t >= first.at[i - 1])).toBe(true);
    expect(first.at[first.at.length - 1]).toBeLessThan(first.end);
    // 「ありがとう。」：前五个字各一份，最后的「。」之后多停三份，所以「。」落在 5/9 处。
    expect(first.at[5]).toBeCloseTo(3.8 + (3 * 5) / 9);
  });

  it("写到第几秒有几个字，拆开时一个都没有", () => {
    const [salutation] = partsOf(letter);
    expect(written(salutation, 0)).toBe(0);
    expect(written(salutation, LEAD_IN)).toBe(1);
    expect(written(salutation, 100)).toBe(4);
  });

  it("签名在最后一块写完 0.8 秒后开始，写 1.6 秒", () => {
    const parts = partsOf(letter, [2, 3, 1.5]);
    expect(signsAt(parts)).toBeCloseTo(10);
    expect(finishesAt(parts)).toBeCloseTo(11.6);
  });

  it("按码点拆字，不拆坏代理对", () => {
    const [salutation] = partsOf({ salutation: "𠮷野さん", paragraphs: [] });
    expect(salutation.chars).toEqual(["𠮷", "野", "さ", "ん"]);
  });
});

describe("跟着她的声音写", () => {
  it("有语音时按每块的实际时长排：每个字落在她念这一块的时候，签名跟着最后一块念完", () => {
    const voiced = partsOf(letter, [2.5, 4, 0.5]);
    const estimated = partsOf(letter);
    expect(spans(voiced)).toEqual([
      [1.2, 3.7],
      [4.3, 8.3],
      [9.2, 9.7],
    ]);
    for (const part of voiced) {
      expect(part.at.every((t) => t >= part.start && t < part.end)).toBe(true);
    }
    expect(signsAt(voiced)).toBeCloseTo(10.5);
    expect(signsAt(voiced)).not.toBeCloseTo(signsAt(estimated));
  });

  it("写到第几秒跟着音频时钟走，开口那一刻是第 0 秒", () => {
    let clock = voiceClock(20, 1000);
    let at: number;
    ({ clock, at } = tick(clock, 1000, 20));
    expect(at).toBe(0);
    ({ clock, at } = tick(clock, 1500, 20.5));
    expect(at).toBeCloseTo(0.5);
    // 音频时钟走得比墙上的钟慢（设备忙），字照样跟着声音。
    ({ clock, at } = tick(clock, 3500, 21));
    expect(at).toBeCloseTo(1);
    expect(clock.by).toBe("voice");
  });

  it("音频时钟停住不到 STALL_MS 时字也停着，等声音", () => {
    let { clock } = tick(voiceClock(0, 0), 0, 3);
    let at: number;
    ({ clock, at } = tick(clock, STALL_MS, 3));
    expect(clock.by).toBe("voice");
    expect(at).toBe(3);
  });

  it("音频时钟停住超过 STALL_MS 就改按时钟，从停下的那一秒接着写", () => {
    let { clock } = tick(voiceClock(0, 0), 0, 3);
    let at: number;
    ({ clock, at } = tick(clock, STALL_MS + 1, 3));
    expect(clock.by).toBe("timer");
    expect(at).toBe(3);
    // 之后不再看音频时钟。
    ({ clock, at } = tick(clock, STALL_MS + 2001, 3));
    expect(at).toBeCloseTo(5);
  });

  it("没有声音时按时钟从第 0 秒写", () => {
    expect(tick(timerClock(1000), 2500, 0).at).toBeCloseTo(1.5);
  });
});

describe("页首的信封键", () => {
  it("开着信，或者已经有信时出现", () => {
    expect(showsLetterButton(true, [])).toBe(true);
    expect(showsLetterButton(false, [summary(true)])).toBe(true);
    expect(showsLetterButton(false, [])).toBe(false);
    expect(showsLetterButton(false, null)).toBe(false);
  });

  it("有没读过的信时带点", () => {
    expect(hasUnread([summary(true), summary(false)])).toBe(true);
    expect(hasUnread([summary(true)])).toBe(false);
    expect(hasUnread(null)).toBe(false);
  });
});

describe("信封上的日期", () => {
  it("今年的只写月日，别的年份带上年", () => {
    expect(letterDay("2026-10-31", 2026)).toBe("10月31日");
    expect(letterDay("2025-02-03", 2026)).toBe("2025年2月3日");
  });
});
