import { readFileSync } from "node:fs";

import { describe, expect, it } from "vitest";

import { availableAudio, BAR_AUDIO, parseManifest } from "@/lib/barAudio";

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

describe("前端的副本 lib/barAudio.json", () => {
  it("和 characters/bar_audio.json 一样（前端镜像只拿得到这一份，改清单时两份一起改）", () => {
    expect(BAR_AUDIO).toEqual(audio);
  });
});

describe("availableAudio", () => {
  const catalog = {
    tracks: [
      { id: 22, file: "022_a.ogg", title: "A" },
      { id: 5, file: "005_b.ogg", title: "B" },
      { id: 9, file: "009_c.ogg", title: "C" },
    ],
    default_playlist: [9, 22, 5],
    sfx: [
      { name: "door", file: "095_door.ogg" },
      { name: "bleep_high", file: "083_bleep_high.ogg" },
    ],
  };

  it("清单和 manifest 都有的才算有，曲目照清单的顺序，默认曲单照它自己的顺序", () => {
    const manifest = { tracks: [5, 9, 77], sfx: ["door", "unknown"] };
    expect(availableAudio(catalog, manifest, true)).toEqual({
      tracks: [catalog.tracks[1], catalog.tracks[2]],
      playlist: [9, 5],
      sfx: ["door"],
    });
  });

  it("没有 manifest、放不了 Ogg 时什么都没有", () => {
    const nothing = { tracks: [], playlist: [], sfx: [] };
    expect(availableAudio(catalog, null, true)).toEqual(nothing);
    expect(availableAudio(catalog, { tracks: [22], sfx: ["door"] }, false)).toEqual(nothing);
  });
});

describe("parseManifest", () => {
  it("读得懂的 manifest 照原样", () => {
    expect(parseManifest({ tracks: [22, 5], sfx: ["door"] })).toEqual({ tracks: [22, 5], sfx: ["door"] });
  });

  it("读不懂的当作没有", () => {
    for (const bad of [null, "x", [], { tracks: ["22"], sfx: [] }, { tracks: [], sfx: [1] }]) {
      expect(parseManifest(bad), JSON.stringify(bad)).toBeNull();
    }
  });
});
