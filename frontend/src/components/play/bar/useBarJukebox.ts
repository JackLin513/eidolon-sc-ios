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
 * - 没有可用的曲目时（`audio` 是空的）`isAvailable` 为假，什么都不放。离开这一页（卸载）时停。
 */
export function useBarJukebox({ userId, audio, base }: { userId: string | null; audio: BarAudio | null; base: string | null }) {
  const isAvailable = audio !== null && hasJukebox(audio);
  const [jukebox, setJukebox] = useState<Jukebox | null>(null);
  const [at, setAt] = useState(0);
  const [isOpen, setOpen] = useState(false);
  const [previewing, setPreviewing] = useState<number | null>(null);
  const latest = useRef<Jukebox | null>(null);
  const atRef = useRef(0);
  const element = useRef<HTMLAudioElement | null>(null);
  const isStarted = useRef(false);

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

  const playSlot = useCallback(
    (slot: number) => {
      const id = latest.current?.slots[slot];
      if (id === null || id === undefined) return;
      let a = element.current;
      if (!a) {
        a = new Audio();
        a.addEventListener("ended", () => {
          const mode = latest.current?.mode ?? "order";
          playSlotRef.current(slotAfter(mode, atRef.current));
        });
        element.current = a;
      }
      a.loop = false;
      a.src = `${base}/music/${id}.ogg`;
      atRef.current = slot;
      setAt(slot);
      void a.play().catch(() => {});
    },
    [base],
  );
  const playSlotRef = useRef(playSlot);
  useEffect(() => {
    playSlotRef.current = playSlot;
  }, [playSlot]);

  // 离开这一页时停。
  useEffect(
    () => () => {
      const a = element.current;
      if (!a) return;
      a.pause();
      a.removeAttribute("src");
      a.load();
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
      else playSlot(atRef.current);
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
  const next = useCallback(() => skipTo(nextSlot(latest.current?.mode ?? "order", atRef.current)), [skipTo]);
  const previous = useCallback(() => skipTo(previousSlot(atRef.current)), [skipTo]);
  const changeMode = useCallback(
    (which: Exclude<JukeboxMode, "order">) => keep({ mode: toggleMode(latest.current?.mode ?? "order", which) }),
    [keep],
  );

  const preview = useCallback(
    (id: number) => {
      const a = (element.current ??= new Audio());
      a.loop = true;
      a.src = `${base}/music/${id}.ogg`;
      setPreviewing(id);
      void a.play().catch(() => {});
    },
    [base],
  );
  const stopPreview = useCallback(() => {
    const a = element.current;
    setPreviewing(null);
    if (!a?.loop) return;
    a.pause();
    a.loop = false;
    a.removeAttribute("src");
    a.load();
  }, []);

  const choose = useCallback(
    (slots: JukeboxSlots) => {
      stopPreview();
      keep({ slots });
    },
    [stopPreview, keep],
  );

  const id = jukebox?.slots[at];
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
    }),
    [isAvailable, jukebox, title, isOpen, start, choose, togglePause, next, previous, changeMode, previewing, preview, stopPreview],
  );
}

export type BarJukebox = ReturnType<typeof useBarJukebox>;
