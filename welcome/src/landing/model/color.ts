// 落地页上每位偶像的一组颜色（拷问记录「角色与光」）。官方色本身不改，另外按同色相推出光晕、
// 极深底色和两种文字色。插值都在 OKLab 里做；光晕的亮度补偿照搬原型（prototype/landing-page 的
// color.ts）拍板过的算法：暗色把光晕抬亮、晕得更开，才在黑底上立得住；太亮的压一点，免得刺眼。
// 这些颜色在服务端算好，以 CSS 变量传给页面，算法不进落地页的包。

import { contrast } from "@/lib/imageColor";

import { hexToLinear, linearToHex, linearToOklab, oklabToLinear } from "./oklab";

export type IdolColors = {
  /** 官方印象色，`#rrggbb`，原样不改。 */
  official: string;
  /** 光晕色：暗色把亮度抬到 0.66 以上（同色相），彩度跟着放大一点。 */
  halo: string;
  /** 光晕强度：太亮的（めぐる的黄、千雪的白）压一点。 */
  haloGain: number;
  /** 光晕宽度的倍数：越暗晕得越开。 */
  haloSpread: number;
  /** 聚焦到她时的背景：她的极深同色相。 */
  deep: string;
  /** 黑底和她的极深底色上写她名字的颜色。 */
  ink: string;
  /** 放在官方色上的字。 */
  onOfficial: string;
  /** 分光时按色相出射的排序键：OKLab 色相角，从粉红起算，依次是红、橙、黄、绿、青、蓝、紫；
   * 近乎无彩色的（千雪的白）排在最后。 */
  hueOrder: number;
};

const AA = 4.5;
/** 色相环从这里切开（OKLab 色相角，度）：粉红排在最前，紫排在最后。 */
const PINK = 345;

export function idolColors(hex: string): IdolColors {
  const official = hex.toLowerCase();
  const [L, a, b] = linearToOklab(hexToLinear(official));
  const C = Math.hypot(a, b);
  const h = Math.atan2(b, a);
  const haloL = Math.min(0.86, Math.max(L, 0.66));
  const haloC = C < 0.02 ? C : Math.min(0.2, C * Math.sqrt(haloL / Math.max(L, 0.05)));
  const deep = oklch(0.2, Math.min(C * 0.45, 0.07), h);
  return {
    official,
    halo: oklch(haloL, haloC, h),
    haloGain: 1 - 0.42 * smooth(0.72, 0.97, L),
    haloSpread: 1 + 0.9 * (1 - smooth(0.25, 0.62, L)),
    deep,
    ink: oklch(0.9, Math.min(C * 0.6, 0.09), h),
    onOfficial: readableOn(official, C, h),
    hueOrder: C < 0.02 ? 1000 : ((h * 180) / Math.PI - PINK + 720) % 360,
  };
}

/** 官方色上她色相的近白或近黑，取对比度高的一边；带了色相还不够清楚，就退到纯白、纯黑。 */
function readableOn(official: string, C: number, h: number): string {
  const tint = Math.min(C * 0.3, 0.04);
  const candidates = [oklch(0.98, tint, h), oklch(0.2, tint, h), "#ffffff", "#000000"];
  const best = (list: string[]) => list.reduce((x, y) => (contrast(y, official) > contrast(x, official) ? y : x));
  const tinted = best(candidates.slice(0, 2));
  return contrast(tinted, official) >= AA ? tinted : best(candidates.slice(2));
}

const smooth = (a: number, b: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

/** OKLCh 转 `#rrggbb`，超出色域时只降彩度。 */
function oklch(L: number, C: number, h: number): string {
  for (let c = C; c >= 0; c -= 0.004) {
    const rgb = oklabToLinear([L, c * Math.cos(h), c * Math.sin(h)]);
    if (rgb.every((x) => x >= -1e-4 && x <= 1 + 1e-4)) return linearToHex(rgb);
  }
  return linearToHex(oklabToLinear([L, 0, 0]));
}
