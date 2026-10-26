"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { BarAudio } from "@/lib/barAudio";
import {
  hasJukebox,
  type Jukebox,
  type JukeboxMode,
  type JukeboxSlots,
  keepJukebox,
  nextSlot,
  previousSlot,
  slotAfter,
  storedJukebox,
  toggleMode,
} from "@/lib/barJukebox";

/**
 * 点唱机（.scratch/bar-room spec「点唱机」）：选的 12 首、小播放器，和放曲目、试听共用的一个 `<audio>`（只下载正在放、
 * 正在试听的那一首）。选择和播放器状态记在这台设备上（lib/barJukebox），manifest 读完、知道是谁以后读出来（`jukebox`）。
 *
 * - `choose(slots)`：选曲界面的 Ready!，存下选择、停掉试听，不放。
 * - `start()` 要在进门那一下点击里调：从第 1 首放起，一首完了照模式接下一首（lib/barJukebox 的 `slotAfter`）；
 *   暂停着的不放；已经开始过就不动（「再营业」、回店门口再进门都不从头放）。
 * - 小播放器：`previous`、`next` 换一首放（暂停着的也放起来），`togglePause`、`toggleMode` 改了就记下。
 * - `preview(id)` 循环放一首试听，`stopPreview()` 停掉。
 * - `loopTrack(id)` 循环放一首（教程的 Every Day is Night），顶掉正在放的；不是试听，也不算开始过：之后进门的 `start()`
 *   照样从第 1 首放起；`stopPreview()` 一样停掉它。没有这一首时什么都不放（正在放的也停）。
 * - 没有可用的曲目时（`audio` 是空的）`isAvailable` 为假，什么都不放。离开这一页（卸载）时停。
 */
export function useBarJukebox({ userId, audio, base }: { userId: string | null; audio: BarAudio | null; base: string | null }) {
  const isAvailable = audio !== null && hasJukebox(audio);
  const [jukebox, setJukebox] = useState<Jukebox | null>(null);
  const [playing, setPlaying] = useState(0);
  const [isOpen, setOpen] = useState(false);
  const [previewing, setPreviewing] = useState<number | null>(null);
  const latest = useRef<Jukebox | null>(null);
  /** The slot playing (or to play once unpaused). */
  const playingRef = useRef(0);
  const element = useRef<HTMLAudioElement | null>(null);
  const isStarted = useRef(false);
  const modeNow = () => latest.current?.mode ?? "order";

  useEffect(() => {
    if (!userId || !audio || !hasJukebox(audio)) return;
    const stored = storedJukebox(userId, audio);
    latest.current = stored;
    setJukebox(stored);
  }, [userId, audio]);

  /** 改一项、记下。 */
  const keep = useCallback(
    (patch: Partial<Jukebox>) => {
      const current = latest.current;
      if (!current || !userId) return;
      const next = { ...current, ...patch };
      latest.current = next;
      setJukebox(next);
      keepJukebox(userId, next);
    },
    [userId],
  );

  /** The one `<audio>`, made the first time: a track ended plays the next by the mode (a preview loops, never ends). */
  const audioElement = useCallback((): HTMLAudioElement => {
    if (!element.current) {
      const a = new Audio();
      a.addEventListener("ended", () => playSlotRef.current(slotAfter(latest.current?.mode ?? "order", playingRef.current)));
      element.current = a;
    }
    return element.current;
  }, []);

  const playSlot = useCallback(
    (slot: number) => {
      const id = latest.current?.slots[slot];
      if (id === null || id === undefined) return;
      const a = audioElement();
      a.loop = false;
      a.src = `${base}/music/${id}.ogg`;
      playingRef.current = slot;
      setPlaying(slot);
      void a.play().catch(() => {});
    },
    [base, audioElement],
  );
  const playSlotRef = useRef(playSlot);
  useEffect(() => {
    playSlotRef.current = playSlot;
  }, [playSlot]);

  // 离开这一页时停。
  useEffect(
    () => () => {
      if (element.current) silence(element.current);
    },
    [],
  );

  const start = useCallback(() => {
    if (isStarted.current || !latest.current) return;
    isStarted.current = true;
    if (!latest.current.isPaused) playSlot(0);
  }, [playSlot]);

  const togglePause = useCallback(() => {
    const current = latest.current;
    const a = element.current;
    if (!current) return;
    if (current.isPaused) {
      keep({ isPaused: false });
      if (a?.getAttribute("src") && !a.loop) void a.play().catch(() => {});
      else playSlot(playingRef.current);
    } else {
      keep({ isPaused: true });
      a?.pause();
    }
  }, [keep, playSlot]);

  const skipTo = useCallback(
    (slot: number) => {
      if (latest.current?.isPaused) keep({ isPaused: false });
      playSlot(slot);
    },
    [keep, playSlot],
  );
  const next = useCallback(() => skipTo(nextSlot(modeNow(), playingRef.current)), [skipTo]);
  const previous = useCallback(() => skipTo(previousSlot(playingRef.current)), [skipTo]);
  const changeMode = useCallback(
    (which: Exclude<JukeboxMode, "order">) => keep({ mode: toggleMode(modeNow(), which) }),
    [keep],
  );

  /** 循环放一首，顶掉正在放的。 */
  const playLooped = useCallback(
    (id: number) => {
      const a = audioElement();
      a.loop = true;
      a.src = `${base}/music/${id}.ogg`;
      void a.play().catch(() => {});
    },
    [base, audioElement],
  );
  const preview = useCallback(
    (id: number) => {
      setPreviewing(id);
      playLooped(id);
    },
    [playLooped],
  );
  const loopTrack = useCallback(
    (id: number) => {
      isStarted.current = false;
      if (audio?.tracks.some((t) => t.id === id)) playLooped(id);
      else if (element.current) silence(element.current); // 没有这一首：静音，曲单也不接着放。
    },
    [audio, playLooped],
  );
  const stopPreview = useCallback(() => {
    const a = element.current;
    setPreviewing(null);
    if (!a?.loop) return;
    a.loop = false;
    silence(a);
  }, []);

  const choose = useCallback(
    (slots: JukeboxSlots) => {
      stopPreview();
      keep({ slots });
    },
    [stopPreview, keep],
  );

  const id = jukebox?.slots[playing];
  const title = audio?.tracks.find((t) => t.id === id)?.title ?? "";
  return useMemo(
    () => ({
      isAvailable,
      jukebox,
      title,
      isOpen,
      toggleOpen: () => setOpen((open) => !open),
      start,
      choose,
      togglePause,
      next,
      previous,
      changeMode,
      previewing,
      preview,
      stopPreview,
      loopTrack,
    }),
    [isAvailable, jukebox, title, isOpen, start, choose, togglePause, next, previous, changeMode, previewing, preview, stopPreview, loopTrack],
  );
}

export type BarJukebox = ReturnType<typeof useBarJukebox>;

/** Stops an `<audio>` and lets go of what it downloaded. */
function silence(a: HTMLAudioElement) {
  a.pause();
  a.removeAttribute("src");
  a.load();
}
