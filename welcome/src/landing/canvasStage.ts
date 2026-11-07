// 按需建的一块 three.js 画布（第 4 幕的手机、第 5 幕的场景）的起落，LightStage 的循环每帧调 frame：滚到它那一段
// 前约一屏才去下载代码和素材、建画布；离开那一段就不画（调用方拿不到这一层）；手指操作的设备上离得再远一点就把
// WebGL 上下文放掉（和立绘一样），回来时重建。画布丢了上下文（不是自己放掉的）、建不起来，就收起、之后不再建，
// 不连带落地页降档。

import type { Quality } from "./model/tier";

/** 这一段开始前多少屏开始下载、建画布（上一段解开钉住的那一屏里）。 */
const LOAD_AHEAD = 1;
/** 离开这一段这么多屏以外，手指操作的设备上放掉上下文。 */
const RELEASE_BEYOND = 1.5;

/** 画在画布上的一层（phoneLayer.ts、memoryLayer.ts）。 */
export type CanvasLayer = {
  /** 画布的 CSS 尺寸（就是视口）。 */
  resize(w: number, h: number): void;
  setQuality(quality: Quality): void;
  /** 放掉 WebGL 上下文。 */
  destroy(): void;
};

export type CanvasStage<L extends CanvasLayer> = {
  /** 每帧调：`scroll` 是滚过的屏数。返回能画的那一层；还没建好、离开了这一段、收起了时是 null。 */
  frame(scroll: number): L | null;
  resize(w: number, h: number): void;
  setQuality(quality: Quality): void;
  /** 收起（落地页退到静态档、卸载）：之后不再建。 */
  drop(): void;
};

export function createCanvasStage<L extends CanvasLayer>({
  host,
  className,
  span,
  touch,
  quality,
  load,
  onDrop,
}: {
  /** 画布放进这里，排在最前面。 */
  host: HTMLElement;
  className: string;
  /** 这一段从第几屏到第几屏。 */
  span: readonly [from: number, to: number];
  touch: boolean;
  quality: Quality;
  /** 在画布上建这一层（动态 import 场景代码、下载素材）；建不起来时 reject。 */
  load: (canvas: HTMLCanvasElement, quality: Quality) => Promise<L>;
  /** 收起以后：丢了上下文、建不起来，或者调用方收起。 */
  onDrop?: () => void;
}): CanvasStage<L> {
  const [from, to] = span;
  let q = quality;
  let size = { w: 1, h: 1 };
  let layer: L | null = null;
  let canvas: HTMLCanvasElement | null = null;
  let building = false;
  let dropped = false;

  // 放掉上下文：自己放的不算丢了。
  const release = () => {
    const c = canvas;
    canvas = null;
    layer?.destroy();
    layer = null;
    c?.remove();
  };

  const drop = () => {
    if (dropped) return;
    dropped = true;
    release();
    onDrop?.();
  };

  const build = async () => {
    building = true;
    const c = document.createElement("canvas");
    c.className = className;
    c.setAttribute("aria-hidden", "true");
    c.addEventListener("webglcontextlost", (e) => {
      if (c !== canvas) return;
      e.preventDefault();
      drop();
    });
    host.prepend(c);
    canvas = c;
    try {
      const l = await load(c, q);
      if (dropped || canvas !== c) return l.destroy();
      l.resize(size.w, size.h);
      layer = l;
    } catch {
      drop();
    } finally {
      building = false;
    }
  };

  return {
    frame(scroll) {
      if (dropped) return null;
      const near = scroll >= from - LOAD_AHEAD && scroll < to + LOAD_AHEAD;
      if (near && !layer && !building) void build();
      const far = scroll < from - LOAD_AHEAD - RELEASE_BEYOND || scroll > to + RELEASE_BEYOND;
      if (far && touch && layer) release();
      return near ? layer : null;
    },
    resize(w, h) {
      size = { w, h };
      layer?.resize(w, h);
    },
    setQuality(next) {
      q = next;
      layer?.setQuality(next);
    },
    drop,
  };
}
