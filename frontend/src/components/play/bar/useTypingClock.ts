"use client";

import { useEffect, useState } from "react";

import { CHARS_PER_SECOND, typedOutAt } from "@/lib/barText";
import type { BarVisitState } from "@/lib/barVisit";

/** How often the box redraws while a page types out: once a character. */
const TYPING_TICK_MS = 1000 / CHARS_PER_SECOND;

/**
 * 文本框的时钟：`shown` 那一页在打字时每个字重画一次（返回现在的时刻），打完时调一次 `tick`（点单句、教程的讲解打完才开调酒台）。
 */
export function useTypingClock(shown: BarVisitState["shown"], tick: (now: number) => void): number {
  const [now, setNow] = useState(() => performance.now());
  useEffect(() => {
    if (!shown) return;
    const end = typedOutAt(shown.page, shown.typing);
    if (shown.typing.finished || performance.now() >= end) {
      setNow(performance.now());
      tick(performance.now());
      return;
    }
    const id = window.setInterval(() => {
      const at = performance.now();
      setNow(at);
      if (at >= end) {
        window.clearInterval(id);
        tick(at);
      }
    }, TYPING_TICK_MS);
    return () => window.clearInterval(id);
  }, [shown, tick]);
  return now;
}
