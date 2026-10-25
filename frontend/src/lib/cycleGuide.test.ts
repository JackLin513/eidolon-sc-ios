import { describe, expect, it } from "vitest";

import { CYCLE_GUIDE, diagramDays, IRREGULAR_BLOCK_ID } from "@/lib/cycleGuide";

describe("diagramDays", () => {
  it("以 28 天为例：经期第 1–5 天，排卵日是第 29 天往前数 14 天的第 15 天，易孕期是它前 5 天到后 1 天", () => {
    const [P, F, O, _] = ["period", "fertile", "ovulation", null] as const;
    const kinds = [P, P, P, P, P, _, _, _, _, F, F, F, F, F, O, F, _, _, _, _, _, _, _, _, _, _, _, _];
    const expected = kinds.map((kind, i) => ({ day: i + 1, kind }));
    expect(diagramDays()).toEqual(expected);
  });
});

describe("CYCLE_GUIDE", () => {
  it("七块依次是怎么算的、基础知识、青春期、经前和经期、常见健康问题、怎么体贴、常见误区", () => {
    expect(CYCLE_GUIDE.map((block) => block.title)).toEqual([
      "怎么算的",
      "基础知识",
      "青春期",
      "经前和经期",
      "常见健康问题",
      "怎么体贴",
      "常见误区",
    ]);
  });

  it("块的 id 不重复，「长短不一」链到的是青春期那一块", () => {
    const ids = CYCLE_GUIDE.map((block) => block.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(CYCLE_GUIDE.find((block) => block.id === IRREGULAR_BLOCK_ID)?.title).toBe("青春期");
  });

  it("每句都带至少一个 https 的来源", () => {
    for (const block of CYCLE_GUIDE) {
      for (const part of block.parts) {
        for (const sentence of part.sentences) {
          expect(sentence.sources.length, sentence.text).toBeGreaterThan(0);
          for (const source of sentence.sources) expect(source.href, sentence.text).toMatch(/^https:\/\//);
        }
      }
    }
  });

  it("「安全期」只出现一次，「危险期」「生理期」「PMS」「预测」不出现", () => {
    const text = CYCLE_GUIDE.flatMap((block) => [
      block.title,
      block.lead,
      ...block.parts.flatMap((part) => [part.heading ?? "", ...part.sentences.map((s) => s.text)]),
    ]).join("\n");
    expect(text.split("「安全期」").length - 1).toBe(1);
    expect(text.replace("「安全期」", "")).not.toMatch(/安全期|危险期|生理期|PMS|预测/);
  });
});
