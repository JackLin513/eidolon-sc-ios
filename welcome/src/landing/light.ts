/**
 * 光层：整页一张 OGL 画布，把落地页模型的画面描述（model/scene.ts）画出来：白光、棱镜、出口附近的
 * 连续色散和每一道光。首屏画出来以后、浏览器空闲时才动态 import 这个模块，OGL 不进首屏的包。
 * 着色器的做法照搬原型拍板的（prototype/landing-page 的 light.ts）：
 *
 * - 每道光 = 白色光芯 + 她的光晕色的光晕；光晕已按亮度反向补偿（model/color.ts）。不做全屏 bloom。
 * - 交叠用 screen，不相加：几道光叠在一起也不会糊成一片白。
 * - 色散只在转场时出现（uDisp > 0）：光芯按 5/3/1 次光谱采样错开，白线两边裂出彩边，
 *   采样位置加逐像素的噪声抖动，少量采样也看不出台阶。
 * - 出口附近的连续色散是唯一允许出现中间色的地方：按扇面上的位置在相邻两道光的颜色之间过渡，
 *   往外就只剩一道道她们自己的颜色。
 * - 第 2 幕名牌上的名字压在光上，那一段光芯断开（模型给出沿光线的区间）。
 * - 第 5 幕不画：那是 3D 画布自己的夜空（memoryLayer.ts），这里只剩页面的底色。
 * - 第 7 幕的手机屏幕是一块圆角矩形的白光，外面一圈很大的光晕：全站最亮的时候。
 * - 最后转回 sRGB，加半个色阶的抖动去色带。背景和页面的底色一样，画布淡入时看不出接缝。
 *
 * OGL 的两个坑（原型踩过）：uniform 数组只认普通数组（它靠 Array.isArray 把 `uA[0]` 对上，
 * Float32Array 对不上，会当成没给值）；Renderer.setSize 会把画布的宽高写成内联样式，所以尺寸
 * 要量画布所在的盒子，不能量画布本身。
 */

import { Mesh, Program, Renderer, Triangle } from "ogl";

import { idle } from "./idle";
import type { Scene } from "./model/scene";
import type { Quality } from "./model/tier";

/** 着色器里最多画几道光。uniform 数组的长度是编译时定的；28 位偶像留了余量，手机的 uniform 上限也放得下。 */
export const MAX_BANDS = 32;

const vertex = /* glsl */ `
attribute vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
`;

const fragment = /* glsl */ `
precision highp float;
uniform vec2 uRes;
uniform float uDpr;
uniform float uTime;
uniform vec3 uBg;
uniform vec4 uBeam;
uniform vec2 uBeamI;
uniform vec4 uPrismAB;
uniform vec4 uPrismC;
uniform vec2 uExit;
uniform vec4 uFan;
uniform vec2 uFan2;
uniform float uDisp;
uniform float uSamples;
uniform float uCount;
uniform vec4 uA[${MAX_BANDS}];
uniform vec4 uC[${MAX_BANDS}];
uniform vec4 uD[${MAX_BANDS}];
uniform vec4 uScreen;
uniform vec2 uScreen2;
uniform vec4 uB[${MAX_BANDS}];

// 交错梯度噪声，当蓝噪声用：色散采样的抖动和最后的去色带。
float ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }

// w: 0 = 红（偏折最小）… 1 = 紫。
vec3 spectral(float w) {
  float x = mix(0.92, 0.08, w);
  vec3 y = vec3(4.0 * (x - 0.75), 4.0 * (x - 0.5), 4.0 * (x - 0.25));
  return max(1.0 - y * y, 0.0);
}

vec3 screen(vec3 a, vec3 b) { return 1.0 - (1.0 - a) * (1.0 - clamp(b, 0.0, 1.0)); }

// 光芯：平时是一条白线；转场时按光谱采样错开，白线的两边裂出彩边。
vec3 core(float perp, float w, float jit) {
  if (uDisp < 0.01 || uSamples < 1.5) { float q = perp / w; return vec3(exp(-q * q)); }
  vec3 acc = vec3(0.0);
  vec3 W = vec3(0.0);
  float wide = w * (1.0 + uDisp * 1.6);
  for (int k = 0; k < 5; k++) {
    if (float(k) >= uSamples) break;
    float t = (float(k) + jit) / uSamples;
    vec3 s = spectral(t);
    float q = (perp + (t - 0.5) * uDisp * 26.0) / wide;
    acc += s * exp(-q * q);
    W += s;
  }
  return acc / max(W, vec3(1e-3)) * (1.0 + uDisp * 0.4);
}

float sdTri(vec2 p, vec2 p0, vec2 p1, vec2 p2) {
  vec2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
  vec2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
  vec2 q0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
  vec2 q1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
  vec2 q2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
  float s = sign(e0.x * e2.y - e0.y * e2.x);
  vec2 d = min(min(vec2(dot(q0, q0), s * (v0.x * e0.y - v0.y * e0.x)),
                   vec2(dot(q1, q1), s * (v1.x * e1.y - v1.y * e1.x))),
                   vec2(dot(q2, q2), s * (v2.x * e2.y - v2.y * e2.x)));
  return -sqrt(d.x) * sign(d.y);
}

float segDist(vec2 p, vec2 a, vec2 b, out float h) {
  vec2 pa = p - a, ba = b - a;
  h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}

void main() {
  vec2 p = vec2(gl_FragCoord.x, uRes.y * uDpr - gl_FragCoord.y) / uDpr;
  float jit = ign(gl_FragCoord.xy);
  vec3 acc = vec3(0.0);

  // —— 白光。
  if (uBeamI.x > 0.003) {
    float h;
    float d = segDist(p, uBeam.xy, uBeam.zw, h);
    vec2 ba = normalize(uBeam.zw - uBeam.xy);
    vec2 pa = p - uBeam.xy;
    float perp = h < 0.999 ? ba.x * pa.y - ba.y * pa.x : d;
    vec3 c = core(perp, 1.6, jit) * vec3(1.0, 0.985, 0.96) * 1.15;
    float halo = exp(-d / 14.0) * 0.32 + exp(-d / 80.0) * 0.06;
    vec3 col = (c + vec3(0.86, 0.9, 1.0) * halo) * uBeamI.x;
    float tipD = length(p - uBeam.zw);
    col += vec3(1.0, 0.97, 0.94) * (exp(-tipD / 7.0) * 0.9 + exp(-tipD / 46.0) * 0.22) * uBeamI.y;
    acc = screen(acc, col);
  }

  // —— 棱镜：玻璃的边、极淡的内部、里面的一段光路；完整档加一点焦散。
  if (uPrismC.z > 0.003) {
    vec2 a = uPrismAB.xy, b = uPrismAB.zw, c = uPrismC.xy;
    float sd = sdTri(p, a, b, c);
    float edge = exp(-(sd * sd) / 0.7) * 0.55 + exp(-abs(sd) / 9.0) * 0.07;
    float inside = 1.0 - smoothstep(-1.0, 1.0, sd);
    float h;
    float pathD = segDist(p, uBeam.zw, uExit, h);
    float path = exp(-(pathD * pathD) / 3.0) * 0.5 + exp(-pathD / 10.0) * 0.12;
    float caustic = 0.0;
    if (uPrismC.w > 0.5) {
      float k = sin(p.x * 0.09 + sin(p.y * 0.06 + uTime * 0.9) * 2.2 + uTime * 0.6);
      caustic = pow(0.5 + 0.5 * k, 14.0) * 0.07 * inside * smoothstep(0.0, -18.0, sd);
    }
    vec3 col = vec3(0.92, 0.95, 1.0) * (edge + inside * 0.028 + caustic) + vec3(1.0) * path * inside;
    acc = screen(acc, col * uPrismC.z);
  }

  // —— 出口附近的连续色散：唯一允许出现中间色的地方，往外吸附成一道道她们自己的颜色。
  if (uFan2.y > 0.003 && uCount > 0.5) {
    vec2 v = p - uFan.xy;
    float r = length(v);
    if (r < uFan2.x) {
      float ang = atan(v.y, v.x) - uFan.z;
      ang = mod(ang + 3.14159265, 6.2831853) - 3.14159265;
      float u = ang / max(uFan.w, 0.003) * 0.5 + 0.5;
      float edge = smoothstep(-0.04, 0.03, u) * (1.0 - smoothstep(0.97, 1.04, u));
      float last = max(uCount - 1.0, 1.0);
      float x = clamp(u, 0.0, 1.0) * last;
      vec3 col = vec3(0.0);
      float ws = 0.0;
      for (int i = 0; i < ${MAX_BANDS}; i++) {
        if (float(i) >= uCount) break;
        float w = max(0.0, 1.0 - abs(x - uD[i].w * last));
        col += uC[i].rgb * w;
        ws += w;
      }
      col /= max(ws, 1e-3);
      col = mix(vec3(1.0), col, smoothstep(0.0, uFan2.x * 0.4, r));
      float fall = (1.0 - smoothstep(uFan2.x * 0.3, uFan2.x, r)) * smoothstep(0.0, 4.0, r);
      acc = screen(acc, col * edge * fall * 0.7 * uFan2.y);
    }
  }

  // —— 每一道光。
  for (int i = 0; i < ${MAX_BANDS}; i++) {
    if (float(i) >= uCount) break;
    vec4 c = uC[i];
    if (c.w < 0.004) continue;
    vec4 a = uA[i];
    vec4 b = uB[i];
    vec4 d = uD[i];
    vec2 v = p - a.xy;
    float perp = a.z * v.y - a.w * v.x;
    float ap = abs(perp);
    if (ap > d.y * 7.0 + 30.0) continue;
    float t = dot(v, a.zw);
    float along = smoothstep(b.y, b.y + 90.0, t) * (1.0 - smoothstep(b.x * 0.8, b.x, t));
    if (along <= 0.0) continue;
    // 名牌上的名字压在光上：那一段光芯断开、光晕收一点，名字才读得清。
    float gap = 0.0;
    if (b.w > b.z + 1.0) gap = smoothstep(b.z - 16.0, b.z + 4.0, t) * (1.0 - smoothstep(b.w - 4.0, b.w + 16.0, t));
    vec3 k = core(perp, d.x, jit) * (1.0 - gap);
    float halo = (exp(-ap / d.y) * 0.45 + exp(-(ap * ap) / (d.y * d.y * 0.08)) * 0.4 * (1.0 - 0.6 * gap)) * d.z;
    // 余烬：光芯比光晕降得更快，暗下去的光剩下的是她的颜色，不是一根白线。
    vec3 col = (mix(vec3(1.0), c.rgb, 0.15) * k * 1.05 * (0.3 + 0.7 * min(c.w, 1.0)) + c.rgb * halo) * c.w * along;
    acc = screen(acc, col);
  }

  // —— 第 7 幕：手机屏幕的白光。
  if (uScreen2.y > 0.003) {
    vec2 q = abs(p - uScreen.xy) - (uScreen.zw - uScreen2.x);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - uScreen2.x;
    float inside = 1.0 - smoothstep(-1.0, 1.0, d);
    float od = max(d, 0.0);
    // 光晕的半径跟着屏幕的大小走：手机上屏幕小，光晕不该铺满整个画面。
    float k = uScreen.z;
    float bloom = exp(-od / (0.18 * k)) * 0.6 + exp(-od / k) * 0.2 + exp(-od / (3.0 * k)) * 0.03;
    float face = 0.92 + 0.08 * (1.0 - (p.y - uScreen.y + uScreen.w) / (2.0 * uScreen.w));
    vec3 col = vec3(1.0, 0.985, 0.965) * (inside * face + (1.0 - inside) * bloom);
    acc = screen(acc, col * uScreen2.y);
  }

  vec3 col = screen(uBg, acc);
  col = mix(12.92 * col, 1.055 * pow(col, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, col));
  col += (jit - 0.5) / 255.0;
  gl_FragColor = vec4(col, 1.0);
}
`;

export type Light = {
  /** 画布所在盒子的 CSS 尺寸。 */
  resize(w: number, h: number): void;
  setQuality(quality: Quality): void;
  render(scene: Scene, time: number): void;
  destroy(): void;
};

/**
 * 建光层。分几批做，每批之间让出主线程：建上下文、编译着色器、画第一帧各占一批，滚动和输入不会
 * 被编译卡住。以后的幕要加着色器时，同样一批编一个，排在这后面。建不起来（不支持 WebGL、
 * 着色器编译失败）时 reject，调用方退到静态档。
 */
export async function createLight(canvas: HTMLCanvasElement, quality: Quality): Promise<Light> {
  const dprOf = (q: Quality) => Math.min(window.devicePixelRatio || 1, q.dprCap);
  const renderer = new Renderer({ canvas, dpr: dprOf(quality), alpha: false, antialias: false, depth: false });
  const gl = renderer.gl;
  await idle();

  const A = new Array<number>(MAX_BANDS * 4).fill(0);
  const B = new Array<number>(MAX_BANDS * 4).fill(0);
  const C = new Array<number>(MAX_BANDS * 4).fill(0);
  const D = new Array<number>(MAX_BANDS * 4).fill(0);
  const program = new Program(gl, {
    vertex,
    fragment,
    depthTest: false,
    depthWrite: false,
    uniforms: {
      uRes: { value: [1, 1] },
      uDpr: { value: renderer.dpr },
      uTime: { value: 0 },
      uBg: { value: [0, 0, 0] },
      uBeam: { value: [0, 0, 0, 0] },
      uBeamI: { value: [0, 0] },
      uPrismAB: { value: [0, 0, 0, 0] },
      uPrismC: { value: [0, 0, 0, 0] },
      uExit: { value: [0, 0] },
      uFan: { value: [0, 0, 0, 0] },
      uFan2: { value: [0, 0] },
      uDisp: { value: 0 },
      uSamples: { value: quality.samples },
      uCount: { value: 0 },
      uA: { value: A },
      uB: { value: B },
      uC: { value: C },
      uD: { value: D },
      uScreen: { value: [0, 0, 0, 0] },
      uScreen2: { value: [0, 0] },
    },
  });
  // OGL 链接失败时只打一条警告就返回，留下一个没有 uniform 表的 Program。
  if (!program.uniformLocations) throw new Error("光层的着色器编译失败");
  const mesh = new Mesh(gl, { geometry: new Triangle(gl), program });
  await idle();

  let q = quality;
  let size = { w: 1, h: 1 };
  const u = program.uniforms;
  const linear = memoLinear();

  const light: Light = {
    resize(w, h) {
      size = { w, h };
      renderer.dpr = dprOf(q);
      renderer.setSize(w, h);
      u.uRes.value = [w, h];
      u.uDpr.value = renderer.dpr;
    },
    setQuality(next) {
      q = next;
      u.uSamples.value = next.samples;
      light.resize(size.w, size.h);
    },
    render(scene, time) {
      const { beam, prism, fan } = scene;
      u.uTime.value = time;
      u.uBg.value = linear(scene.background);
      u.uBeam.value = [beam.x0, beam.y0, beam.x1, beam.y1];
      u.uBeamI.value = [beam.intensity, beam.tip];
      u.uPrismAB.value = [prism.apex[0], prism.apex[1], prism.left[0], prism.left[1]];
      u.uPrismC.value = [prism.right[0], prism.right[1], prism.intensity, q.caustics ? 1 : 0];
      u.uExit.value = [prism.exit[0], prism.exit[1]];
      u.uFan.value = [fan.x, fan.y, fan.angle, fan.spread];
      u.uFan2.value = [fan.radius, fan.intensity];
      u.uDisp.value = q.samples > 1 ? scene.dispersion : 0;
      const bands = scene.bands.slice(0, MAX_BANDS);
      u.uCount.value = bands.length;
      bands.forEach((b, i) => {
        const [r, g, bl] = linear(b.color);
        put(A, i, b.x, b.y, b.dx, b.dy);
        put(B, i, b.length, b.start, b.gap0, b.gap1);
        put(C, i, r, g, bl, b.intensity);
        put(D, i, b.core, b.halo, b.gain, b.hue);
      });
      const sc = scene.screen;
      u.uScreen.value = [sc.x, sc.y, sc.w, sc.h];
      u.uScreen2.value = [sc.r, sc.intensity];
      // A–D 是就地改的：OGL 把上一帧传过的值另存一份来比较，改过的照样会重传。
      renderer.render({ scene: mesh });
    },
    destroy() {
      gl.getExtension("WEBGL_lose_context")?.loseContext();
    },
  };
  return light;
}

function put(arr: number[], i: number, x: number, y: number, z: number, w: number) {
  arr[i * 4] = x;
  arr[i * 4 + 1] = y;
  arr[i * 4 + 2] = z;
  arr[i * 4 + 3] = w;
}

/** `#rrggbb` 转线性 sRGB；颜色就那么几十种，算过的记下来，不每帧重算。 */
function memoLinear() {
  const seen = new Map<string, [number, number, number]>();
  const channel = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return (hex: string) => {
    let rgb = seen.get(hex);
    if (!rgb) {
      const n = parseInt(hex.slice(1), 16);
      rgb = [channel(((n >> 16) & 255) / 255), channel(((n >> 8) & 255) / 255), channel((n & 255) / 255)];
      seen.set(hex, rgb);
    }
    return rgb;
  };
}
