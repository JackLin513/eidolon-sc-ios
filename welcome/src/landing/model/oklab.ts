// sRGB、线性 sRGB 和 OKLab 之间的换算。落地页的颜色插值都在 OKLab 里做（拷问记录「角色与光」）：
// 服务端推出每位偶像的一组颜色（color.ts），浏览器里也要实时插值（聚焦时的背景、来电时背景跟着铃声亮，scene.ts），
// 所以单独一个小模块，不带对比度算法。

export type Vec3 = [number, number, number];

const toLinear = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const toSrgb = (c: number) => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);

export function hexToLinear(hex: string): Vec3 {
  const n = parseInt(hex.slice(1), 16);
  return [toLinear(((n >> 16) & 255) / 255), toLinear(((n >> 8) & 255) / 255), toLinear((n & 255) / 255)];
}

export function linearToHex(rgb: Vec3): string {
  return `#${rgb
    .map((x) =>
      Math.round(Math.min(1, Math.max(0, toSrgb(x))) * 255)
        .toString(16)
        .padStart(2, "0"),
    )
    .join("")}`;
}

export function linearToOklab([r, g, b]: Vec3): Vec3 {
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

export function oklabToLinear([L, a, b]: Vec3): Vec3 {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
  return [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ];
}

/** 两个 `#rrggbb` 在 OKLab 里按 t 插值：t 为 0 是 a，为 1 是 b。 */
export function mixOklab(a: string, b: string, t: number): string {
  if (t <= 0) return a;
  if (t >= 1) return b;
  const p = linearToOklab(hexToLinear(a));
  const q = linearToOklab(hexToLinear(b));
  return linearToHex(oklabToLinear([p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t]));
}

/** 几种颜色按权重在 OKLab 里取平均；权重都是 0 时是 null。 */
export function averageOklab(colors: readonly (readonly [hex: string, weight: number])[]): string | null {
  let W = 0;
  const sum: Vec3 = [0, 0, 0];
  for (const [hex, w] of colors) {
    if (w <= 0) continue;
    const lab = linearToOklab(hexToLinear(hex));
    for (let k = 0; k < 3; k++) sum[k] += lab[k] * w;
    W += w;
  }
  return W > 0 ? linearToHex(oklabToLinear([sum[0] / W, sum[1] / W, sum[2] / W])) : null;
}
