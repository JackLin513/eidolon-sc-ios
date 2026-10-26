"use client";

import { useCallback, useEffect, useState } from "react";

import { primaryPointer } from "@/components/play/bar/BarScreen";

/** Full screen, then on a phone locked in landscape (the lock is refused out of full screen, and
 * desktop Chrome has `lock` but it always fails); left as it is when either fails. */
export async function goFullscreen(): Promise<void> {
  try {
    await document.documentElement.requestFullscreen();
    const orientation = screen.orientation as ScreenOrientation & { lock?: (to: string) => Promise<void> };
    if (primaryPointer() === "coarse" && typeof orientation?.lock === "function") await orientation.lock("landscape");
  } catch {
    // 不行就留在原样，自己转过来。
  }
}

/**
 * 「全屏」（.scratch/bar-room 票 14）：店门口和侧边菜单那一格。浏览器能进全屏（`canFullscreen`，挂上以后才知道）就有，
 * 电脑也有；iPhone 进不了，没有。跟着 `fullscreenchange` 走（`isFullscreen`）：返回手势、Esc 退出以后变回「全屏」，能再点。
 * `toggle()` 没全屏时进全屏（手机再锁横屏），全屏时退出。
 */
export function useBarFullscreen() {
  const [canFullscreen, setCanFullscreen] = useState(false);
  const [isFullscreen, setFullscreen] = useState(false);
  useEffect(() => {
    setCanFullscreen(document.fullscreenEnabled);
    const read = () => setFullscreen(document.fullscreenElement !== null);
    read();
    document.addEventListener("fullscreenchange", read);
    return () => document.removeEventListener("fullscreenchange", read);
  }, []);
  const toggle = useCallback(() => {
    if (document.fullscreenElement) void document.exitFullscreen().catch(() => {});
    else void goFullscreen();
  }, []);
  return { canFullscreen, isFullscreen, toggle };
}
