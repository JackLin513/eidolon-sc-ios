// The bar's settings (.scratch/bar-room 票 14): the original's settings box, its 「全屏」 and
// 「窗口化」 left out. Two volumes, the music's (the jukebox's tracks and previews) and the sound
// effects' (typing included), each in tenths, and the original's scanlines over the screen, on or
// off. Kept on this device, per user, as the jukebox is (lib/barJukebox); never on the server.

/** A volume, in tenths: 0 (silent) to 10 (full, as the file is). */
export const VOLUME_STEPS = 10;

export type BarSettings = { music: number; sfx: number; scanlines: boolean };

export const DEFAULT_SETTINGS: BarSettings = { music: VOLUME_STEPS, sfx: VOLUME_STEPS, scanlines: false };

/** A volume as a gain, 0 to 1. */
export function gainOf(steps: number): number {
  return steps / VOLUME_STEPS;
}

/** A volume `by` tenths up or down (the slider's −/+), no further than silent or full. */
export function stepVolume(steps: number, by: number): number {
  return Math.min(VOLUME_STEPS, Math.max(0, steps + by));
}

// 原版的滑条 140×17：两头是 −/+（各 18 宽），中间的槽从 x=19 到 x=120（102 宽）；滑块 4 宽，左边从 19 走到 117。

/** Where the slider's groove is in its sprite, and how wide its knob is. */
export const SLIDER = { groove: 19, grooveWidth: 102, knobWidth: 4 };

/** The knob's left edge in the slider sprite, for a volume. */
export function knobX(steps: number): number {
  return SLIDER.groove + Math.round(gainOf(steps) * (SLIDER.grooveWidth - SLIDER.knobWidth));
}

/** The volume a point of the slider sprite (`x`, from its left) stands for, the knob centred on it:
 * the nearest tenth, no further than the groove's ends. */
export function volumeAt(x: number): number {
  const travel = SLIDER.grooveWidth - SLIDER.knobWidth;
  const along = (x - SLIDER.groove - SLIDER.knobWidth / 2) / travel;
  return Math.min(VOLUME_STEPS, Math.max(0, Math.round(along * VOLUME_STEPS)));
}

// 存在 localStorage 里，按用户分开（键 eidolon.barSettings.<用户 ID>），照 lib/barJukebox 的存法：读不出时用这次页面里
// 记着的，存不进去（无痕浏览）时只在这次页面里记着。不存服务器，不进数据包。

function storageKey(userId: string): string {
  return `eidolon.barSettings.${userId}`;
}

/** 这次页面里记着的，按用户。 */
const keptThisPage = new Map<string, BarSettings>();

function isVolume(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= VOLUME_STEPS;
}

/** 这位用户在这台设备上记着的设置。读不懂的各项用默认的：音量不是 0–10 的整数时满的，扫描线不是真假时关着。 */
export function storedSettings(userId: string): BarSettings {
  const kept = keptThisPage.get(userId);
  if (kept) return kept;
  let stored: unknown = null;
  try {
    stored = JSON.parse(localStorage.getItem(storageKey(userId)) ?? "null");
  } catch {
    // 读不出或者坏了：都用默认的。
  }
  const { music, sfx, scanlines } = (typeof stored === "object" && stored !== null ? stored : {}) as Record<string, unknown>;
  return {
    music: isVolume(music) ? music : DEFAULT_SETTINGS.music,
    sfx: isVolume(sfx) ? sfx : DEFAULT_SETTINGS.sfx,
    scanlines: typeof scanlines === "boolean" ? scanlines : DEFAULT_SETTINGS.scanlines,
  };
}

/** 记下这位用户的设置。 */
export function keepSettings(userId: string, settings: BarSettings): void {
  keptThisPage.set(userId, settings);
  try {
    localStorage.setItem(storageKey(userId), JSON.stringify(settings));
  } catch {
    // 存不进去：只在这次页面里记着。
  }
}
