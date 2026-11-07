// 第 5 幕「记忆」的布景和镜头（.scratch/landing-memory-3d/spec.md「落地页模型」）：一片夜空里四座浮岛，
// 四位演员各站在一座上；正交相机斜着俯看（仰角固定 35.264°，正等轴测），随幕内进度沿原型定下的关键帧
// 推近、拉远、转向。3D 层（memoryLayer.ts）按这里摆相机、搭布景，DOM 上要跟着场景走的东西按 project 摆，
// 两边同一个出处才对得齐。随进度讲的那件事在 memoryStory.ts：它跟着第 5 幕的场景代码晚加载，不算首屏。
// 纯函数，不碰 DOM。
//
// 世界坐标：y 朝上，一个单位约是一位小人身高的六成；四座岛按演员的顺序（发送的人、接收并传开的人、
// 再传到的两位）。

import type { Point, Viewport } from "./scene";

export type Vec3 = readonly [x: number, y: number, z: number];

/** 第 5 幕的演员：落地页文案指定的四位里在名单上的那几位，在服务端准备好。 */
export type Actor = {
  id: string;
  /** 体素加载不到时，方块上写的名字。 */
  name: string;
  /** 官方印象色，`#rrggbb`：她脚下的地砖、加载不到时的方块。 */
  color: string;
  /** 体素文件的地址（角色接口的 voxels_url）；没有时站着的是她印象色的方块。 */
  voxels: string | null;
  /** 站在第几座岛上（ISLANDS 的下标）：0 发送的人，1 接收并传开的人，2、3 再传到的两位。 */
  island: number;
};

/** 四座浮岛柱顶的中心，按演员的顺序：真乃、果穗、冬优子、雾子。 */
export const ISLANDS: readonly Vec3[] = [
  [0, 0, 0],
  [5, 0, 0],
  [5, -2, 5],
  [10, 2, 0],
];
/** 柱顶是边长这么多的正方形。 */
export const ISLAND_SIZE = 3;
/** 小人在场景里的身高（脚底到头顶，原型定下的）：体素按 `front` 缩放到这么高。 */
export const FIGURE_HEIGHT = 1.7;

const DEG = Math.PI / 180;
/** 镜头的仰角：正等轴测的 35.264°，横平竖直的东西看起来各边一样长。 */
export const ELEVATION = 35.264 * DEG;

/** 镜头关键帧（原型定下的）：幕内进度、注视点、取景半径（画面高度的一半，世界单位）、方位角（度）。
 * 相邻两帧之间按 smoothstep 插值。 */
export const CAMERA: readonly { p: number; target: Vec3; r: number; az: number }[] = [
  { p: 0, target: [3.6, 0.2, 0.6], r: 9.0, az: 45 },
  { p: 0.07, target: [2.6, 1.2, 0.6], r: 7.4, az: 42 },
  { p: 0.17, target: [0, 1.0, 0.1], r: 3.2, az: 38 },
  { p: 0.29, target: [0.2, 0.7, -0.1], r: 3.0, az: 52 },
  { p: 0.4, target: [2.5, 0.4, 0.2], r: 5.0, az: 28 },
  { p: 0.53, target: [5, 0.8, 0], r: 3.4, az: 36 },
  { p: 0.62, target: [5.1, 0.6, 0.3], r: 3.6, az: 48 },
  { p: 0.72, target: [7, 0, 2.2], r: 7.0, az: 62 },
  { p: 0.84, target: [7.2, 0, 2.2], r: 6.6, az: 50 },
  { p: 1, target: [4.2, -0.2, 1.2], r: 8.8, az: 45 },
];

export type MemoryCamera = {
  /** 注视点：画面正中。 */
  target: Vec3;
  /** 关键帧插出来的取景半径。 */
  radius: number;
  /** 方位角（弧度）：镜头在注视点的 (sin, cos) 方向上，0 是从 +z 看过去。 */
  azimuth: number;
  /** 实际取景的半高（世界单位）。取景半径管的是画面短的那一边：横屏就是 radius；竖屏按宽高比放大，
   * 横向也是 radius，两边的人和东西才不出画面。 */
  half: number;
};

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
const smooth = (a: number, b: number, x: number) => {
  const t = clamp01((x - a) / (b - a));
  return t * t * (3 - 2 * t);
};
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/** 幕内进度 p 时的镜头。 */
export function cameraAt(p: number, vp: Viewport): MemoryCamera {
  let k = 0;
  while (k < CAMERA.length - 2 && p > CAMERA[k + 1].p) k++;
  const a = CAMERA[k];
  const b = CAMERA[k + 1];
  const t = smooth(a.p, b.p, p);
  const radius = lerp(a.r, b.r, t);
  const aspect = vp.w / vp.h;
  return {
    target: [lerp(a.target[0], b.target[0], t), lerp(a.target[1], b.target[1], t), lerp(a.target[2], b.target[2], t)],
    radius,
    azimuth: lerp(a.az, b.az, t) * DEG,
    half: aspect >= 1 ? radius : radius / aspect,
  };
}

/**
 * 镜头的三个方向（单位向量）：`back` 从注视点指向镜头，`right`、`up` 是画面的右和上。和 three.js 的
 * Object3D.lookAt（up 是 +y）算出来的一样，3D 层把相机放在注视点沿 back 退开的地方、看向注视点。
 */
export function cameraBasis(camera: MemoryCamera): { back: Vec3; right: Vec3; up: Vec3 } {
  const s = Math.sin(camera.azimuth);
  const c = Math.cos(camera.azimuth);
  const se = Math.sin(ELEVATION);
  const ce = Math.cos(ELEVATION);
  return { back: [s * ce, se, c * ce], right: [c, 0, -s], up: [-se * s, ce, -se * c] };
}

/** 世界坐标 `point` 落在画面上的哪里（视口坐标，像素）：正交投影，画面高度是 2 × half 个世界单位。 */
export function project(camera: MemoryCamera, vp: Viewport, point: Vec3): Point {
  const { right, up } = cameraBasis(camera);
  const d = [point[0] - camera.target[0], point[1] - camera.target[1], point[2] - camera.target[2]];
  const u = d[0] * right[0] + d[1] * right[1] + d[2] * right[2];
  const v = d[0] * up[0] + d[1] * up[1] + d[2] * up[2];
  const scale = vp.h / 2 / camera.half;
  return [vp.w / 2 + u * scale, vp.h / 2 - v * scale];
}

/** 第 5 幕的场景状态：镜头和画布的不透明度。随进度讲的那件事由 3D 层按 `progress` 和镜头去问 memoryStory.ts。 */
export type MemoryScene = {
  /** 幕内进度 0 到 1。 */
  progress: number;
  camera: MemoryCamera;
  /** 3D 画布的不透明度：第 4 幕解开钉住的那一屏里淡入，这一幕解开钉住的那一屏里淡出。 */
  opacity: number;
};

/** 幕内进度 p 时的场景状态，画布的不透明度是 `opacity`。 */
export const memoryAt = (p: number, vp: Viewport, opacity: number): MemoryScene => ({ progress: p, camera: cameraAt(p, vp), opacity });

/** 事先渲染好的终局全景图（scripts/landing-memory-still.mjs，定格档、静态档和 3D 画布出问题时用）的尺寸（像素）：
 * 按电脑上的取景（横屏，取景半高就是取景半径）渲染，页面按这个比例排它。 */
export const MEMORY_STILL = { w: 1920, h: 1200 } as const;
