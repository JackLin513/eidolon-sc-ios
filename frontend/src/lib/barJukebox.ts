// 点唱机（.scratch/bar-room spec「点唱机」）：选曲界面的 12 个槽、小播放器的上一首 / 下一首 / 随机 / 单曲循环，
// 和它们在这台设备上的存法。曲目按原版的声音编号（lib/barAudio 的 `id`）记，一个槽一首，可以重复。

import type { BarAudio, BarTrack } from "@/lib/barAudio";

/** 选曲界面的槽数：选满这么多首才 Ready!。 */
export const SLOTS = 12;

/** 12 个槽，一个槽一首曲目的编号，空槽是 null。 */
export type JukeboxSlots = (number | null)[];

/** 默认的 12 首：清单的默认曲单（只算桶里有的），缺的几首空着。 */
export function defaultSlots(audio: BarAudio): JukeboxSlots {
  return Array.from({ length: SLOTS }, (_, i) => audio.playlist[i] ?? null);
}

/** 点曲名：放进第一个空槽；满了不变。 */
export function pickTrack(slots: JukeboxSlots, id: number): JukeboxSlots {
  const at = slots.indexOf(null);
  return at < 0 ? slots : slots.map((s, i) => (i === at ? id : s));
}

/** 点两个槽：对调。 */
export function swapSlots(slots: JukeboxSlots, a: number, b: number): JukeboxSlots {
  const next = [...slots];
  [next[a], next[b]] = [next[b], next[a]];
  return next;
}

/** 清掉一个槽，后面的不补位。 */
export function clearSlot(slots: JukeboxSlots, at: number): JukeboxSlots {
  return slots.map((s, i) => (i === at ? null : s));
}

/** 12 个槽满了才 Ready!。 */
export function isReady(slots: JukeboxSlots): slots is number[] {
  return slots.length === SLOTS && slots.every((s) => s !== null);
}

/** 左边一页几首曲名。 */
const PAGE_SIZE = 5;

/** 左边的曲名有几页：桶里有几首算几首（原版 59 首是 12 页）。 */
export function jukeboxPages(tracks: BarTrack[]): number {
  return Math.ceil(tracks.length / PAGE_SIZE);
}

/** 第 `page` 页（从 0 起）的曲名。 */
export function jukeboxPage(tracks: BarTrack[], page: number): BarTrack[] {
  return tracks.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
}

/** 点唱机能不能用：桶里一首曲目都没有（没有 manifest、放不了 Ogg）时整块不可用。 */
export function hasJukebox(audio: BarAudio): boolean {
  return audio.tracks.length > 0;
}

/** 放完一首接哪首：顺序、随机、单曲循环（随机和单曲循环互斥，所以是一个）。 */
export type JukeboxMode = "order" | "shuffle" | "loop";
const MODES: readonly JukeboxMode[] = ["order", "shuffle", "loop"];

/** 这台设备上记着的：选的 12 首和小播放器的状态。 */
export type Jukebox = { slots: JukeboxSlots; isPaused: boolean; mode: JukeboxMode };

// 存在 localStorage 里，按用户分开（键 eidolon.barJukebox.<用户 ID>），照 lib/seenOnDevice 的存法：读不出时用
// 这次页面里记着的，存不进去（无痕浏览）时只在这次页面里记着。不存服务器，不进数据包。

function storageKey(userId: string): string {
  return `eidolon.barJukebox.${userId}`;
}

/** 这次页面里记着的，按用户。 */
const keptThisPage = new Map<string, Jukebox>();

/** 这位用户在这台设备上记着的点唱机。读不懂的各项用默认的：槽不是 12 首桶里有的曲目时是默认的（lib/barAudio 的默认曲单），
 * 暂停不是真假时在放，模式认不得时顺序放。 */
export function storedJukebox(userId: string, audio: BarAudio): Jukebox {
  const kept = keptThisPage.get(userId);
  if (kept) return kept;
  let stored: unknown = null;
  try {
    stored = JSON.parse(localStorage.getItem(storageKey(userId)) ?? "null");
  } catch {
    // 读不出或者坏了：都用默认的。
  }
  const { slots, isPaused, mode } = (typeof stored === "object" && stored !== null ? stored : {}) as Record<string, unknown>;
  const ids = new Set(audio.tracks.map((t) => t.id));
  const isSlots = Array.isArray(slots) && slots.length === SLOTS && slots.every((id) => ids.has(id));
  return {
    slots: isSlots ? (slots as number[]) : defaultSlots(audio),
    isPaused: typeof isPaused === "boolean" ? isPaused : false,
    mode: MODES.find((m) => m === mode) ?? "order",
  };
}

/** 记下这位用户的点唱机。 */
export function keepJukebox(userId: string, jukebox: Jukebox): void {
  keptThisPage.set(userId, jukebox);
  try {
    localStorage.setItem(storageKey(userId), JSON.stringify(jukebox));
  } catch {
    // 存不进去：只在这次页面里记着。
  }
}

/** 随便一个别的槽（`random` 给 [0, 1) 的数）。 */
function anotherSlot(at: number, random: () => number): number {
  const pick = Math.floor(random() * (SLOTS - 1));
  return pick >= at ? pick + 1 : pick;
}

/** 第 `at` 个槽（从 0 起）放完了接着放哪个：单曲循环再放这一个，随机随便一个别的，顺序放下一个、第 12 个完了从头。 */
export function slotAfter(mode: JukeboxMode, at: number, random: () => number = Math.random): number {
  if (mode === "loop") return at;
  return nextSlot(mode, at, random);
}

/** 小播放器的「下一首」：随机时随便一个别的槽，不然下一个（单曲循环也往下）。 */
export function nextSlot(mode: JukeboxMode, at: number, random: () => number = Math.random): number {
  return mode === "shuffle" ? anotherSlot(at, random) : (at + 1) % SLOTS;
}

/** 小播放器的「上一首」：上一个槽，第 1 个往回是第 12 个。 */
export function previousSlot(at: number): number {
  return (at - 1 + SLOTS) % SLOTS;
}

/** 点随机或单曲循环：开着的关掉；关着的开起来，另一个随之关掉。 */
export function toggleMode(mode: JukeboxMode, which: "shuffle" | "loop"): JukeboxMode {
  return mode === which ? "order" : which;
}
