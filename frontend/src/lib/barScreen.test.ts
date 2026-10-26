import { describe, expect, it } from "vitest";

import { barScreen, type BarViewport, hasFullscreenButton } from "@/lib/barScreen";

const NO_INSETS = { top: 0, right: 0, bottom: 0, left: 0 };

function viewport(change: Partial<BarViewport> = {}): BarViewport {
  return { width: 1280, height: 720, insets: NO_INSETS, callBar: 0, pointer: "fine", ...change };
}

describe("酒吧画面的缩放和位置", () => {
  it("电脑上 1280×720 正好放大 2 倍，铺满", () => {
    expect(barScreen(viewport())).toEqual({ scale: 2, left: 0, top: 0 });
  });

  it("电脑上取放得下的最大整数倍，居中", () => {
    expect(barScreen(viewport({ width: 1920, height: 1080 }))).toEqual({ scale: 3, left: 0, top: 0 });
    expect(barScreen(viewport({ width: 1500, height: 900 }))).toEqual({ scale: 2, left: 110, top: 90 });
  });

  it("电脑上放不下 1 倍时退成小数", () => {
    expect(barScreen(viewport({ width: 480, height: 600 }))).toEqual({ scale: 0.75, left: 0, top: 165 });
  });

  it("手机上取放得下的最大小数倍", () => {
    const { scale, left, top } = barScreen(viewport({ width: 844, height: 390, pointer: "coarse" }));

    expect(scale).toBeCloseTo(390 / 360);
    expect(top).toBe(0);
    expect(left).toBe(75);
  });

  it("扣掉通话条：画面在通话条下面那一块里，位置从那一块算起", () => {
    expect(barScreen(viewport({ callBar: 48 }))).toEqual({ scale: 1, left: 320, top: 156 });
  });

  it("扣掉安全区", () => {
    const { scale, left, top } = barScreen(
      viewport({ width: 844, height: 390, pointer: "coarse", insets: { top: 0, right: 47, bottom: 21, left: 47 } }),
    );

    expect(scale).toBeCloseTo(369 / 360);
    expect(top).toBe(0);
    expect(left).toBe(47 + Math.floor((750 - 640 * (369 / 360)) / 2));
  });
});

describe("「全屏横过来」按钮", () => {
  it("手机上能进全屏、能锁方向（安卓）时才有", () => {
    expect(hasFullscreenButton({ canLockOrientation: true, canFullscreen: true, pointer: "coarse" })).toBe(true);
  });

  it("锁不了方向（iPhone）时没有", () => {
    expect(hasFullscreenButton({ canLockOrientation: false, canFullscreen: true, pointer: "coarse" })).toBe(false);
    expect(hasFullscreenButton({ canLockOrientation: false, canFullscreen: false, pointer: "coarse" })).toBe(false);
  });

  it("电脑上没有（电脑的 Chrome 也有 lock，但锁不了）", () => {
    expect(hasFullscreenButton({ canLockOrientation: true, canFullscreen: true, pointer: "fine" })).toBe(false);
  });
});
