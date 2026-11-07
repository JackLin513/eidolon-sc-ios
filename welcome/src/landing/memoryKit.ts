// 第 5 幕 3D 场景（memoryLayer.ts）和它的布景（memoryDressing.ts）共用的几样东西：建场景时的一套小工具，画布当贴图，
// 往下渐隐进夜色的柱子，固定种子的伪随机数。跟场景代码一起晚加载。

import {
  BoxGeometry,
  BufferAttribute,
  type BufferGeometry,
  CanvasTexture,
  Color,
  type Material,
  type MeshBasicMaterial,
  type MeshBasicMaterialParameters,
  type MeshLambertMaterial,
  type MeshLambertMaterialParameters,
  type Object3D,
  type Scene,
  Sprite,
  SpriteMaterial,
  SRGBColorSpace,
} from "three";

/** 柱子的侧面往下渐隐成这个颜色：夜空渐变中段的颜色，光照以后再混，柱脚才融进夜空、不发黑。 */
export const NIGHT = "#151030";
/** 浮岛的柱子、远处的楼往下伸到这么低：竖屏取景高，柱脚不能露在画面里。 */
export const PILLAR_FOOT = -32;

/** 建场景时的一套小工具：建出来的几何、材质、贴图记下来，放掉上下文时一起释放。 */
export type Kit = {
  scene: Scene;
  own: <T extends { dispose(): void }>(x: T) => T;
  lambert: (params: MeshLambertMaterialParameters) => MeshLambertMaterial;
  basic: (params: MeshBasicMaterialParameters) => MeshBasicMaterial;
  /** 一团叠加混合的光（glowTexture），按 `color` 上色，放进 `parent`。 */
  glow: (color: Color | string, size: number, parent: Object3D) => Sprite;
  /** 把 `o` 放到 `parent` 里的 (x, y, z)。 */
  place: <T extends Object3D>(o: T, parent: Object3D, x?: number, y?: number, z?: number) => T;
  /** 柱子的材质：顶点色，按 pillarGeometry 的 `fade` 属性往下渐隐进夜色。 */
  pillarMat: Material;
};

/**
 * 一根柱子：截面 `w` × `d`（`d` 不给就是正方形），顶面在 `top`，往下 `depth` 深。顶面是 `topColor`，侧面是 `color`；
 * `fade` 属性是侧面融进夜色的程度（fadeIntoNight），往下 `fade` 深（不给就是 `depth`）的地方完全融进去。侧面竖着切成
 * 一段段，渐隐才照着曲线走，不是首尾之间的直线。
 */
export function pillarGeometry({
  w,
  d = w,
  top,
  depth,
  fade = depth,
  x,
  z,
  color = "#8d79b3",
  topColor = "#e6dbf2",
}: {
  w: number;
  d?: number;
  top: number;
  depth: number;
  fade?: number;
  x: number;
  z: number;
  color?: string;
  topColor?: string;
}): BufferGeometry {
  const g = new BoxGeometry(w, depth, d, 1, Math.max(1, Math.ceil(depth / 2))).toNonIndexed();
  g.translate(x, top - depth / 2, z);
  const pos = g.getAttribute("position");
  const nor = g.getAttribute("normal");
  const colors = new Float32Array(pos.count * 3);
  const fades = new Float32Array(pos.count);
  const side = new Color(color);
  const lit = new Color(topColor);
  for (let i = 0; i < pos.count; i++) {
    const c = nor.getY(i) > 0.5 ? lit : side;
    colors.set([c.r, c.g, c.b], i * 3);
    fades[i] = nor.getY(i) > 0.5 ? 0 : Math.min(1, Math.max(0, (top - pos.getY(i)) / fade)) ** 0.8;
  }
  g.setAttribute("color", new BufferAttribute(colors, 3));
  g.setAttribute("fade", new BufferAttribute(fades, 1));
  return g;
}

/** 光照算完以后，按顶点的 `fade` 属性把颜色混向夜空的颜色。 */
export function fadeIntoNight<M extends Material>(m: M): M {
  const night = new Color(NIGHT);
  m.onBeforeCompile = (shader) => {
    shader.uniforms.uNight = { value: night };
    shader.vertexShader = shader.vertexShader
      .replace("#include <common>", `#include <common>
attribute float fade;
varying float vFade;`)
      .replace("#include <begin_vertex>", `#include <begin_vertex>
  vFade = fade;`);
    shader.fragmentShader = shader.fragmentShader
      .replace("#include <common>", `#include <common>
uniform vec3 uNight;
varying float vFade;`)
      .replace("#include <opaque_fragment>", `outgoingLight = mix(outgoingLight, uNight, vFade);
#include <opaque_fragment>`);
  };
  return m;
}

/** 一块画布当贴图。 */
export function canvasTexture(w: number, h: number, draw: (g: CanvasRenderingContext2D) => void): CanvasTexture {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  draw(c.getContext("2d")!);
  const t = new CanvasTexture(c);
  t.colorSpace = SRGBColorSpace;
  return t;
}

/** 一团白光（叠加混合，按材质的颜色上色）：记忆方块、手机、气泡、路灯外面的光晕。 */
export function glowTexture(): CanvasTexture {
  return canvasTexture(64, 64, (g) => {
    const grad = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    grad.addColorStop(0, "rgba(255,255,255,0.9)");
    grad.addColorStop(0.25, "rgba(255,255,255,0.35)");
    grad.addColorStop(1, "rgba(255,255,255,0)");
    g.fillStyle = grad;
    g.fillRect(0, 0, 64, 64);
  });
}

/** 胶囊字的样子：`font` 是 canvas 的字体（字重、字号、字族），`bg`、`fg` 是底色和字色。 */
export type PillStyle = { font: string; bg: string; fg: string };

/** 半透明胶囊里的一行字，做成总是朝着镜头的精灵，高 `height` 个世界单位。 */
export function pillSprite(own: Kit["own"], text: string, { font, bg, fg }: PillStyle, height: number): Sprite {
  const probe = document.createElement("canvas").getContext("2d")!;
  probe.font = font;
  const w = Math.ceil(probe.measureText(text).width) + 48;
  const map = own(
    canvasTexture(w, 72, (g) => {
      g.fillStyle = bg;
      g.beginPath();
      g.roundRect(0, 0, w, 72, 36);
      g.fill();
      g.font = font;
      g.fillStyle = fg;
      g.textBaseline = "middle";
      g.fillText(text, 24, 38);
    }),
  );
  const sprite = new Sprite(own(new SpriteMaterial({ map, transparent: true, depthWrite: false })));
  sprite.scale.set((height * w) / 72, height, 1);
  return sprite;
}

/** 固定种子的伪随机数（0 到 1）：布景每次一样。 */
export function seeded(seed: number) {
  let s = seed;
  return () => (s = (s * 16807) % 2147483647) / 2147483647;
}
