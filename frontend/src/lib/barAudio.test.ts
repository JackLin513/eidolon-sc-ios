import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

// 运行时读，不 import：前端的 Docker 构建拿不到 characters/，而 next build 也给测试做类型检查。
const audio = JSON.parse(readFileSync(new URL("../../../characters/bar_audio.json", import.meta.url), "utf-8")) as {
  tracks: { id: number; file: string; title: string }[];
  default_playlist: number[];
  sfx: { name: string; file: string }[];
};

describe("characters/bar_audio.json", () => {
  it("原版点唱机的 59 首，编号唯一、都有显示名，照原版的顺序", () => {
    expect(audio.tracks).toHaveLength(59);
    expect(new Set(audio.tracks.map((t) => t.id)).size).toBe(59);
    for (const track of audio.tracks) {
      expect(track.title.trim()).not.toBe("");
      expect(track.file).toMatch(/^\d{3}_[a-z0-9_]+\.ogg$/);
    }
    expect(audio.tracks[0].title).toBe("Hopes and Dreams");
    expect(audio.tracks.at(-1)?.title).toBe("Re: Base of the Titans");
  });

  it("默认的 12 首都在表里，从 Every Day is Night、Dusk、Last Call 开始", () => {
    const ids = new Set(audio.tracks.map((t) => t.id));
    expect(audio.default_playlist).toHaveLength(12);
    for (const id of audio.default_playlist) expect(ids).toContain(id);
    const title = (id: number) => audio.tracks.find((t) => t.id === id)?.title;
    expect(audio.default_playlist.slice(0, 3).map(title)).toEqual(["Every Day is Night", "Dusk", "Last Call"]);
  });

  it("音效名字唯一，含打字、点唱机、悬停、提示和门声", () => {
    const names = audio.sfx.map((s) => s.name);
    expect(names).toHaveLength(16);
    expect(new Set(names).size).toBe(names.length);
    for (const name of ["bleep_high", "bleep_low", "jukeselect", "jukepick", "jukechange", "mouse_hover", "prompt", "door"]) {
      expect(names).toContain(name);
    }
    for (const sfx of audio.sfx) expect(sfx.file).toMatch(/^\d{3}_[a-z_]+\.ogg$/);
  });
});
