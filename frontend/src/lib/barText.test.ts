import { describe, expect, it } from "vitest";

import { isTypedOut, paginate, shownRows, typedChars, typedOutAt, type TextLine } from "@/lib/barText";

/** Like the pixel font: CJK a whole square, the rest half of one. */
function measure(text: string): number {
  let width = 0;
  for (const ch of text) width += (ch.codePointAt(0) ?? 0) >= 0x2e80 ? 12 : 6;
  return width;
}

const NAMES = { her: "真乃", producer: "制作人" };

function pages(line: TextLine) {
  return paginate(line, { names: NAMES, measure });
}

describe("文本框分页", () => {
  it("制作人一句中文一行，名字接冒号在同一行开头", () => {
    expect(pages({ speaker: "producer", zh: "欢迎光临。" })).toEqual([
      { rows: [{ name: "制作人：", text: "欢迎光临。", subtitle: false }] },
    ]);
  });

  it("她一句是日语一行、中文字幕一行", () => {
    expect(pages({ speaker: "her", ja: "こんばんは。", zh: "晚上好。" })).toEqual([
      {
        rows: [
          { name: "真乃：", text: "こんばんは。", subtitle: false },
          { name: null, text: "晚上好。", subtitle: true },
        ],
      },
    ]);
  });

  it("一行放不下就折行，名字占掉第一行的宽度", () => {
    // 宽 400：第一行扣掉「制作人：」48，放得下 29 个字；之后每行 33 个字。
    const zh = "一".repeat(29) + "二".repeat(33) + "三".repeat(5);

    expect(pages({ speaker: "producer", zh })[0].rows.map((row) => row.text)).toEqual([
      "一".repeat(29),
      "二".repeat(33),
      "三".repeat(5),
    ]);
  });

  it("日语和中文各自折行", () => {
    const ja = "あ".repeat(30) + "い".repeat(3);
    const zh = "中".repeat(33) + "文";

    expect(pages({ speaker: "her", ja, zh })[0].rows.map((row) => [row.text, row.subtitle])).toEqual([
      ["あ".repeat(30), false],
      ["い".repeat(3), false],
      ["中".repeat(33), true],
      ["文", true],
    ]);
  });

  it("英文单词不从中间断开，太长的才断", () => {
    const zh = "一".repeat(27) + "我要 Sugar Rush";
    const rows = pages({ speaker: "producer", zh })[0].rows.map((row) => row.text);

    expect(rows).toEqual(["一".repeat(27) + "我要", "Sugar Rush"]);
    expect(pages({ speaker: "producer", zh: "a".repeat(70) })[0].rows.map((row) => row.text)).toEqual([
      "a".repeat(58),
      "a".repeat(12),
    ]);
  });

  it("句末的标点挂在行尾，不放到下一行开头", () => {
    const zh = "一".repeat(29) + "。";

    expect(pages({ speaker: "producer", zh })[0].rows.map((row) => row.text)).toEqual(["一".repeat(29) + "。"]);
  });

  it("超过 4 行分页，接着的页没有名字", () => {
    const ja = "あ".repeat(30 + 33 + 33);
    const zh = "中".repeat(40);
    const [first, second] = pages({ speaker: "her", ja, zh });

    expect(first.rows.map((row) => [row.name, row.text.length, row.subtitle])).toEqual([
      ["真乃：", 30, false],
      [null, 33, false],
      [null, 33, false],
      [null, 33, true],
    ]);
    expect(second.rows.map((row) => [row.name, row.text.length, row.subtitle])).toEqual([[null, 7, true]]);
  });
});

describe("打字", () => {
  const producer = pages({ speaker: "producer", zh: "一二三四五六七八九十" })[0];
  const her = pages({ speaker: "her", ja: "あいうえおかきくけこ", zh: "甲乙丙丁戊" })[0];

  it("每秒 30 字", () => {
    expect(typedChars(producer, { startedAt: 1000, finished: false }, 1000)).toBe(0);
    expect(typedChars(producer, { startedAt: 1000, finished: false }, 1000 + 100)).toBe(3);
    expect(typedChars(producer, { startedAt: 1000, finished: false }, 1000 + 250)).toBe(7);
    expect(typedChars(producer, { startedAt: 1000, finished: false }, 1000 + 5000)).toBe(10);
  });

  it("打完的时刻", () => {
    expect(typedOutAt(producer, { startedAt: 1000, finished: false })).toBe(1000 + 334);
    expect(isTypedOut(producer, { startedAt: 1000, finished: false }, 1000 + 333)).toBe(false);
    expect(isTypedOut(producer, { startedAt: 1000, finished: false }, 1000 + 334)).toBe(true);
  });

  it("点一下打完整句", () => {
    expect(typedChars(producer, { startedAt: 1000, finished: true }, 1000)).toBe(10);
    expect(isTypedOut(producer, { startedAt: 1000, finished: true }, 1000)).toBe(true);
  });

  it("名字一开始就在，正文打到第几个字露到第几个字", () => {
    expect(shownRows(producer, 3)).toEqual([{ name: "制作人：", text: "一二三", subtitle: false }]);
  });

  it("她的中文字幕跟着日语的进度出来，打字的时长按日语算", () => {
    expect(typedChars(her, { startedAt: 0, finished: false }, 10_000)).toBe(10);
    expect(shownRows(her, 4).map((row) => row.text)).toEqual(["あいうえ", "甲乙"]);
    expect(shownRows(her, 10).map((row) => row.text)).toEqual(["あいうえおかきくけこ", "甲乙丙丁戊"]);
  });

  it("只剩中文字幕的一页照中文打", () => {
    const [, rest] = pages({ speaker: "her", ja: "あ".repeat(30 + 33 + 33), zh: "中".repeat(40) });

    expect(typedChars(rest, { startedAt: 0, finished: false }, 10_000)).toBe(7);
    expect(shownRows(rest, 2).map((row) => row.text)).toEqual(["中中"]);
  });
});
