import { describe, expect, it } from "vitest";

import { TUTORIAL, TUTORIAL_START, type TutorialSectionId } from "@/lib/barTutorialLines";

const EMOTIONS = ["calm", "happy", "shy", "surprised", "sad", "angry", "thinking"];
const SECTIONS = Object.entries(TUTORIAL) as [TutorialSectionId, (typeof TUTORIAL)[TutorialSectionId]][];

/** 像素字下大致占几个全角字：ASCII 半个，其余一个。 */
function width(text: string): number {
  return [...text].reduce((sum, ch) => sum + (ch.charCodeAt(0) < 0x80 ? 0.5 : 1), 0);
}

/** 文本框 412 宽、13px 字：一行按 30 个全角字算，留点余地。 */
const ROW = 30;
const rows = (text: string) => Math.ceil(width(text) / ROW);

/** 从 `from` 照 `then` 往下走能到的段（上酒的每种结果都走一遍）。 */
function reachable(from: TutorialSectionId): Set<TutorialSectionId> {
  const seen = new Set<TutorialSectionId>();
  const walk = (id: TutorialSectionId) => {
    if (seen.has(id)) return;
    seen.add(id);
    const then = TUTORIAL[id].then;
    if (then.type === "section") walk(then.section);
    if (then.type === "mixer") Object.values(then.reactions).forEach(walk);
  };
  walk(from);
  return seen;
}

/** 从 `from` 走到底经过的段；上酒时按 `served` 的饮品 id 接（不在反应里的算 other）。 */
function path(served: string[]): TutorialSectionId[] {
  const out: TutorialSectionId[] = [];
  let id: TutorialSectionId | null = TUTORIAL_START;
  const cups = [...served];
  while (id) {
    out.push(id);
    const then: (typeof TUTORIAL)[TutorialSectionId]["then"] = TUTORIAL[id].then;
    if (then.type === "section") id = then.section;
    else if (then.type === "mixer") {
      const drink = cups.shift()!;
      id = then.reactions[drink as keyof typeof then.reactions] ?? then.reactions.other;
    } else id = null;
  }
  return out;
}

describe("教程台词", () => {
  it("每一段都在", () => {
    expect(Object.keys(TUTORIAL).sort()).toEqual(
      [
        "opening",
        "lesson1",
        "first.sugar-rush",
        "first.piano-man",
        "first.other",
        "lesson2",
        "second.moonblast",
        "second.other",
        "closing",
        "jukebox",
      ].sort(),
    );
  });

  it.each(SECTIONS)("%s：有台词、有备忘，每句的说话人、语言和情绪都齐", (_, section) => {
    expect(section.lines.length).toBeGreaterThan(0);
    expect(section.memo.trim()).not.toBe("");
    for (const line of section.lines) {
      expect(EMOTIONS).toContain(line.emotion);
      expect(line.zh.trim()).not.toBe("");
      if (line.who === "her") expect(line.ja.trim()).not.toBe("");
      else expect(line).not.toHaveProperty("ja");
    }
  });

  it.each(SECTIONS)("%s：每句一页放得下，备忘两行放得下", (_, section) => {
    for (const line of section.lines) {
      // 名字接冒号在同一行开头（她「はづき：」，制作人的名字按 8 个字算）；她的日语、中文各自折行；最多 4 行。
      const used = line.who === "her" ? rows(`はづき：${line.ja}`) + rows(line.zh) : rows(`一二三四五六七：${line.zh}`);
      expect(used, line.zh).toBeLessThanOrEqual(4);
    }
    // 侧边菜单上排 172 宽、两行，前面有「点单　」三个字。
    expect(Math.ceil((3 + width(section.memo)) / 13), section.memo).toBeLessThanOrEqual(2);
  });

  it("只有两段讲解打完以后打开调酒台：第一杯分三种反应，第二杯分两种", () => {
    const mixers = SECTIONS.filter(([, s]) => s.then.type === "mixer").map(([id, s]) => [id, s.then]);
    expect(mixers).toEqual([
      ["lesson1", { type: "mixer", reactions: { "sugar-rush": "first.sugar-rush", "piano-man": "first.piano-man", other: "first.other" } }],
      ["lesson2", { type: "mixer", reactions: { moonblast: "second.moonblast", other: "second.other" } }],
    ]);
  });

  it("每一段都走得到，每条路都接上收尾和点唱机那句", () => {
    expect([...reachable(TUTORIAL_START)].sort()).toEqual(Object.keys(TUTORIAL).sort());
    const tail = ["closing", "jukebox"];
    expect(path(["sugar-rush", "moonblast"])).toEqual([
      "opening",
      "lesson1",
      "first.sugar-rush",
      "lesson2",
      "second.moonblast",
      ...tail,
    ]);
    expect(path(["sugar-rush", "sugar-rush"]).slice(-3)).toEqual(["second.other", ...tail]);
    expect(path(["blue-fairy", "moonblast"])).toEqual([
      "opening",
      "lesson1",
      "first.other",
      "lesson2",
      "second.moonblast",
      ...tail,
    ]);
    expect(path(["blue-fairy", "piano-man"]).slice(-3)).toEqual(["second.other", ...tail]);
  });

  it("第一杯调成 Piano Man 跳过第二课，直接收尾，台词不提第二课", () => {
    expect(path(["piano-man"])).toEqual(["opening", "lesson1", "first.piano-man", "closing", "jukebox"]);
    const said = (id: TutorialSectionId) => TUTORIAL[id].lines.map((l) => `${l.who === "her" ? l.ja : ""}${l.zh}`).join("");
    for (const id of ["first.piano-man", "closing", "jukebox"] as const) {
      expect(said(id)).not.toMatch(/ムーンブラスト|Moonblast|ブレンド|调和|もう一杯|再来一杯/);
    }
  });

  it("不讲讨厌的口味、上得最好、醉的门槛、电视、快捷键、离开", () => {
    const all = SECTIONS.flatMap(([, s]) => [s.memo, ...s.lines.flatMap((l) => (l.who === "her" ? [l.ja, l.zh] : [l.zh]))]).join("\n");
    expect(all).not.toMatch(/讨厌|苦手|嫌い|最好|ベスト|门槛|電視|电视|テレビ|快捷键|キーボード|键盘|Shift|离开|退出/);
  });

  it("点唱机那句单独一段，接在收尾后面，走完就结束（取不到音频时整段省掉）", () => {
    expect(TUTORIAL.closing.then).toEqual({ type: "section", section: "jukebox" });
    expect(TUTORIAL.jukebox.then).toEqual({ type: "done" });
    expect(TUTORIAL.jukebox.lines.map((l) => l.zh).join("")).toMatch(/12 首/);
  });
});
