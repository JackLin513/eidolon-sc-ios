// How big the bar's screen is drawn and where (.scratch/bar-room spec「画框和缩放」): the original's
// 640×360 logical screen, scaled into what is left of the viewport once the safe area and the call
// bar across the top are taken away. With a mouse (`pointer: fine`) it is the largest whole multiple
// that fits, so the pixels stay crisp, and a fraction only when not even 1× fits; with a finger
// (`pointer: coarse`) it is the largest fraction that fits, drawn `pixelated`. Whether the Android
// 「全屏横过来」 button is offered depends on what the browser can do.

/** The logical screen, in the original's pixels. */
export const BAR_WIDTH = 640;
export const BAR_HEIGHT = 360;

export type BarPointer = "fine" | "coarse";

/** The viewport in CSS pixels, its safe-area insets (`env(safe-area-inset-*)`), how tall the call
 * bar across its top is (0 when there is none) and the primary pointer. */
export type BarViewport = {
  width: number;
  height: number;
  insets: { top: number; right: number; bottom: number; left: number };
  callBar: number;
  pointer: BarPointer;
};

/** The screen's scale, and its top-left corner in CSS pixels from the top-left of the block under
 * the call bar, centred in what is left of it. */
export type BarPlacement = { scale: number; left: number; top: number };

export function barScreen({ width, height, insets, callBar, pointer }: BarViewport): BarPlacement {
  const top = Math.max(insets.top - callBar, 0);
  const free = {
    width: Math.max(width - insets.left - insets.right, 0),
    height: Math.max(height - callBar - top - insets.bottom, 0),
  };
  const fits = Math.min(free.width / BAR_WIDTH, free.height / BAR_HEIGHT);
  const scale = pointer === "fine" && fits >= 1 ? Math.floor(fits) : fits;
  return {
    scale,
    left: insets.left + Math.floor((free.width - BAR_WIDTH * scale) / 2),
    top: top + Math.floor((free.height - BAR_HEIGHT * scale) / 2),
  };
}

/** What the browser can do, as far as going full screen in landscape goes. */
export type BarAbilities = { canLockOrientation: boolean; canFullscreen: boolean; pointer: BarPointer };

/** Whether to offer 「全屏横过来」: only on a phone that can go full screen and lock the screen's
 * orientation (Android). iPhones cannot lock it; desktop Chrome has `lock` but it always fails. */
export function hasFullscreenButton({ canLockOrientation, canFullscreen, pointer }: BarAbilities): boolean {
  return pointer === "coarse" && canLockOrientation && canFullscreen;
}
