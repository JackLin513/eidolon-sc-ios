// 落地页的档位（拷问记录「分档」，原型 page.tsx 的首屏前定档和 Landing.tsx 的按帧降档）。
// 首屏前按设备的几个信号定初始档；运行中按帧时只降不升，降过就不再回来，免得画面来回跳。
// 每档决定画布要不要、动不动、DPR 上限、色散采样次数、焦散，和第 5 幕场景的阴影、泛光、粒子。纯函数，不碰 DOM。

/**
 * - `full` 完整档：电脑；
 * - `lite` 简化档：触屏，或完整档掉帧以后；
 * - `basic`：简化档还掉帧时再降一步，色散只剩 1 次采样（原型按帧降档的第二步）；
 * - `reduced` 定格档：开了「减少动态效果」，着色器只画一帧定格的画面；
 * - `static` 静态档：省流量或不支持 WebGL，不加载画布，光由 CSS/SVG 画。
 */
export type Tier = "full" | "lite" | "basic" | "reduced" | "static";

export const TIERS: readonly Tier[] = ["full", "lite", "basic", "reduced", "static"];

/** 首屏前读得到的信号。 */
export type Signals = {
  /** `navigator.connection.saveData`。 */
  saveData: boolean;
  /** 能不能建出 WebGL 上下文。 */
  webgl: boolean;
  /** `(prefers-reduced-motion: reduce)`。 */
  reducedMotion: boolean;
  /** `(hover: none)`：手指操作的设备。 */
  hoverNone: boolean;
};

/**
 * 定初始档的规则：按顺序看，第一条成立的信号决定档位，都不成立是完整档。首屏前的内联脚本
 * （tierScript.ts）照这张表逐条探测，探到就停，所以省流量时不会去建 WebGL 上下文。
 */
export const TIER_RULES: readonly (readonly [signal: "saveData" | "noWebgl" | "reducedMotion" | "hoverNone", tier: Tier])[] = [
  ["saveData", "static"],
  ["noWebgl", "static"],
  ["reducedMotion", "reduced"],
  ["hoverNone", "lite"],
];

export function initialTier(signals: Signals): Tier {
  const holds = { ...signals, noWebgl: !signals.webgl };
  return TIER_RULES.find(([signal]) => holds[signal])?.[1] ?? "full";
}

export type Quality = {
  /** 要不要加载 OGL 画布。 */
  canvas: boolean;
  /** 逐帧动画；定格档只画一帧。 */
  animate: boolean;
  /** DPR 上限，实际取它和设备 DPR 的小者。 */
  dprCap: number;
  /** 色散的光谱采样次数；1 就是不做色散。 */
  samples: 5 | 3 | 1;
  /** 棱镜里的焦散。 */
  caustics: boolean;
  /** 第 4 幕的手机上，前玻璃和相机镜片那几层半透明的反光。 */
  reflections: boolean;
  /** 第 5 幕的场景里，主光投下的阴影和发光处的泛光。 */
  shadowsAndBloom: boolean;
  /** 第 5 幕的场景里，飘的花瓣、上飘的 token 粒子画多少（全部的几分之几）。 */
  particles: 1 | 0.5;
};

/** 每档的画质。`touch` 是手指操作的设备：完整档在手机上 DPR 不超过 1.5，电脑上不超过 2。 */
export function qualityOf(tier: Tier, touch: boolean): Quality {
  // 第 5 幕的场景只在运动档里画，定格档、静态档用不上阴影、泛光和粒子。
  const sceneOff = { shadowsAndBloom: false, particles: 0.5 } as const;
  switch (tier) {
    case "full":
      return { canvas: true, animate: true, dprCap: touch ? 1.5 : 2, samples: 5, caustics: true, reflections: true, shadowsAndBloom: true, particles: 1 };
    case "lite":
      return { canvas: true, animate: true, dprCap: 1, samples: 3, caustics: false, reflections: false, ...sceneOff };
    case "basic":
      return { canvas: true, animate: true, dprCap: 1, samples: 1, caustics: false, reflections: false, ...sceneOff };
    case "reduced":
      // 定格的那一帧没有色散，采样次数用不上。
      return { canvas: true, animate: false, dprCap: 1.5, samples: 1, caustics: false, reflections: false, ...sceneOff };
    case "static":
      return { canvas: false, animate: false, dprCap: 1, samples: 1, caustics: false, reflections: false, ...sceneOff };
  }
}

/** 竖排的静止版式（不钉住、不横滚）还是钉住加滚动驱动的运动版式。 */
export const layoutOf = (tier: Tier): "motion" | "still" => (tier === "reduced" || tier === "static" ? "still" : "motion");

/**
 * - `frames`：一段时间里的平均帧耗时（毫秒）。量多久由调用方决定（原型是至少 90 帧、2.5 秒）。
 * - `lost`：WebGL 上下文建不起来或丢了。
 */
export type TierAction = { type: "frames"; averageMs: number } | { type: "lost" };

/** 平均帧耗时超过它就降到下一档：完整档掉到四十来帧就降，简化档掉到三十帧以下才降。 */
export const SLOW_MS: Partial<Record<Tier, [ms: number, next: Tier]>> = {
  full: [24, "lite"],
  lite: [36, "basic"],
};

export function tierReducer(tier: Tier, action: TierAction): Tier {
  if (action.type === "lost") return "static";
  const step = SLOW_MS[tier];
  return step && action.averageMs > step[0] ? step[1] : tier;
}
