// How often and how sharply the stand is drawn (spec「渲染」): measured on a phone, 60 frames
// a second and a pixel ratio of at most 2 look as good as more and cost less battery.

/** The most frames a second the stand is drawn, whatever the display's refresh rate. */
export const MAX_FPS = 60;

/** The highest pixel ratio the stand's canvas is rendered at. */
export const MAX_PIXEL_RATIO = 2;

const FRAME_MS = 1000 / MAX_FPS;

/** A frame arriving this much early still counts as on time: display frames jitter. */
const SLACK_MS = 1;

/**
 * Decides, for each of the display's animation frames, whether the stand draws in it: every
 * frame on a 60Hz display or slower, and on faster ones (90, 120, 144Hz) only as many as keep
 * it at 60 a second.
 */
export class FrameGate {
  private due = Number.NEGATIVE_INFINITY;

  /** Whether to draw in the animation frame at `now` (milliseconds). */
  shouldDraw(now: number): boolean {
    if (now < this.due - SLACK_MS) return false;
    // Keep to the 60Hz beat; after a pause (a hidden tab, a collapsed layer) start afresh
    // from now rather than catching up.
    const next = this.due + FRAME_MS;
    this.due = next < now ? now + FRAME_MS : next;
    return true;
  }
}

/** The pixel ratio to render at: the device's, but no more than `max` (`MAX_PIXEL_RATIO` unless
 * the place showing the stand caps it lower). */
export function pixelRatio(devicePixelRatio: number, max = MAX_PIXEL_RATIO): number {
  if (!(devicePixelRatio > 0)) return 1;
  return Math.min(devicePixelRatio, max);
}
