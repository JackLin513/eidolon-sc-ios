"use client";

import { useEffect, useState } from "react";

import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";
import { copy } from "@/i18n";
import { hasFullscreenButton } from "@/lib/barScreen";

const t = copy.bar;

/** How many times the reminder's pixel words are drawn: not tied to the screen's scale, which is
 * small while the phone is upright. */
const SCALE = 3;

/** What this browser can do about going full screen in landscape. */
function canGoFullscreenLandscape(): boolean {
  const orientation = screen.orientation as ScreenOrientation & { lock?: unknown };
  return hasFullscreenButton({
    canLockOrientation: typeof orientation?.lock === "function",
    canFullscreen: document.fullscreenEnabled,
    pointer: matchMedia("(pointer: coarse)").matches ? "coarse" : "fine",
  });
}

/** Full screen first, then locked in landscape (the lock is refused out of full screen); left as
 * it is when either fails. */
export async function goFullscreenLandscape(): Promise<void> {
  try {
    await document.documentElement.requestFullscreen();
    await (screen.orientation as ScreenOrientation & { lock: (to: string) => Promise<void> }).lock("landscape");
  } catch {
    // 不行就留在提醒上，自己转过来。
  }
}

/** Whether to offer 「全屏横过来」 here: known once mounted (the server has no screen). */
export function useFullscreenButton(): boolean {
  const [isOffered, setOffered] = useState(false);
  useEffect(() => setOffered(canGoFullscreenLandscape()), []);
  return isOffered;
}

/**
 * 竖屏提醒（.scratch/bar-room spec「画框和缩放」）：手机（粗指针）竖着时整层盖上「请横过来」（CSS 媒体查询，
 * bar.css 的 `.bar-portrait-guard`），下面的画面不卸下，横过来接着玩。安卓（能锁方向）下面多一个「全屏横过来」：
 * 先进全屏，再锁成横屏；iPhone 没有这个按钮。字是像素字，按固定的 3 倍画。
 */
export function PortraitGuard() {
  const isOffered = useFullscreenButton();
  return (
    <div
      role="alert"
      className="bar-portrait-guard bar-stage absolute inset-0 flex-col items-center justify-center"
      style={{ background: BAR_INK.ground, gap: 8 * SCALE }}
    >
      <div className="relative" style={{ width: 96 * SCALE, height: 16 * SCALE }}>
        <div className="absolute top-0 left-0" style={{ transform: `scale(${SCALE})`, transformOrigin: "0 0" }}>
          <PixelText x={0} y={0} width={96} align="center" runs={t.portrait} />
        </div>
      </div>
      {isOffered && (
        <button
          type="button"
          aria-label={t.fullscreen}
          className="bar-hit relative"
          style={{ width: 96 * SCALE, height: 22 * SCALE, border: `${SCALE}px solid ${BAR_INK.pink}` }}
          onClick={() => void goFullscreenLandscape()}
        >
          <span className="absolute top-0 left-0" style={{ transform: `scale(${SCALE})`, transformOrigin: "0 0" }}>
            <PixelText x={-1} y={2} width={96} align="center" runs={t.fullscreen} color={BAR_INK.pink} label="" />
          </span>
        </button>
      )}
    </div>
  );
}
