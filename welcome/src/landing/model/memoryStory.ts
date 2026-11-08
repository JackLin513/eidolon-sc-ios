// 第 5 幕「记忆」随幕内进度讲的那件事（.scratch/landing-memory-3d/spec.md「落地页模型」，原型的节拍表）：制作人的消息
// 落到真乃那里、收进她的记忆柱，一份副本过桥传给果穗，再沿台阶传给冬优子和雾子，最后四根柱顶都是真乃颜色的方块。
// 往回滚一切倒着走：只看进度，不记历史。岛上的布景常量（她站的地方、记忆柱、转台、台阶、路线）也在这里。3D 层
// （memoryLayer.ts）每帧按它摆东西。它和第 5 幕的场景代码一起晚加载，不进首屏（落地页首屏 JS 的预算）；镜头和投影在
// memory.ts，这里只从那边拿类型（验收脚本用 Node 直接读这个文件，不经打包）。纯函数，不碰 DOM。下面的时刻都是幕内进度。

import type { MemoryCamera, Vec3 } from "./memory";

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
const smooth = (a: number, b: number, x: number) => {
  const t = clamp01((x - a) / (b - a));
  return t * t * (3 - 2 * t);
};
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const lerp3 = (a: Vec3, b: Vec3, t: number): Vec3 => [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];

/** 每座岛上她站的地方（脚底）。 */
export const STANDS: readonly Vec3[] = [
  [-0.2, 0, 0.45],
  [4.75, 0, 0.45],
  [4.75, -2, 5.3],
  [9.5, 2, 0.5],
];

/** 节拍：每一拍从 `at` 开始。 */
export const BEATS: readonly { at: number; name: string }[] = [
  { at: 0, name: "全景" },
  { at: 0.08, name: "你给真乃发了条消息" },
  { at: 0.18, name: "真乃想了想，收进记忆" },
  { at: 0.3, name: "转台转动，桥接上" },
  { at: 0.42, name: "记忆沿桥传给果穗" },
  { at: 0.53, name: "果穗想起它、说起它" },
  { at: 0.64, name: "台阶升起" },
  { at: 0.74, name: "传给冬优子和雾子" },
  { at: 0.86, name: "全景：都是真乃的颜色" },
];

/** 每座岛上的记忆柱（数据库图标样子的三层圆盘）的底面中心，按岛的顺序。 */
export const MEMORY_PILLARS: readonly Vec3[] = [
  [0.65, 0, -0.55],
  [5.65, 0, -0.35],
  [5.7, -2, 4.55],
  [10.3, 2, -0.3],
];
/** 记忆柱的高度。 */
export const MEMORY_PILLAR_HEIGHT = 0.55;
/** 记忆方块的边长。 */
export const BLOCK = 0.3;
/** 第 k 座岛的记忆柱顶上那块记忆方块的中心。 */
export const memoryTop = (k: number): Vec3 => {
  const [x, y, z] = MEMORY_PILLARS[k];
  return [x, y + MEMORY_PILLAR_HEIGHT + BLOCK / 2 + 0.08, z];
};

/** 背景的 embedding 星图上，发送那一位收进记忆时亮起的那颗点：远在浮岛后面，镜头拉远去看桥的那段（电脑）和最后的全景
 * （电脑在右上的天空，竖屏在右边）都看得到。 */
export const EMBEDDING_STAR: Vec3 = [2.5, -1.5, -9.5];
/** 天上那台制作人的手机的中心：消息从它的屏幕里出来。 */
export const PHONE: Vec3 = [-0.4, 5.6, 1.4];
/** 真乃在头顶上方接住消息的地方。 */
const CATCH: Vec3 = [STANDS[0][0] + 0.15, STANDS[0][1] + 2.05, STANDS[0][2]];

/** 真乃和果穗之间的转台的中心（顶面）：上面两块桥面沿 x 排开，转过 90° 才接上两边。 */
export const TURNTABLE: Vec3 = [2.5, 0, 0];
/** 两块桥面在转台上的位置（转台接上以后沿 x，相对转台中心），边长 1。 */
export const BRIDGE = [-0.5, 0.5] as const;

/** 两段台阶，各四级：第 0 段从果穗往南下到冬优子，第 1 段往东上到雾子。`center` 是升好以后的中心，
 * `size` 是长宽高；`delay` 是这一级在「台阶升起」里晚多少（0 到 1）。 */
export const STEPS: readonly { stair: 0 | 1; center: Vec3; size: Vec3; delay: number }[] = [0, 1, 2, 3].flatMap((i) => [
  { stair: 0 as const, center: [5, -0.5 * (i + 1) - 0.25, 1.75 + 0.5 * i] as Vec3, size: [1, 0.5, 0.5] as Vec3, delay: i * 0.12 },
  { stair: 1 as const, center: [6.75 + 0.5 * i, 0.5 * (i + 1) - 0.25, 0] as Vec3, size: [0.5, 0.5, 1] as Vec3, delay: i * 0.12 + 0.06 },
]);

/** 每一位把记忆收进柱子的时刻，按岛的顺序。 */
const STORED_AT = [0.28, 0.53, 0.84, 0.85];
/** 传出去的三份：从哪座岛到哪座岛、什么时候沿路线从头走到尾，路线经过哪几个点（两头是两边的柱顶）、
 * 走过哪几块桥面或台阶（沿 x 还是 z、从哪到哪），一路是不是跳着走（下台阶、上台阶时一级跳一下）。 */
const COPIES: readonly { from: number; to: number; go: readonly [number, number]; via: readonly Vec3[]; hops: number }[] = [
  { from: 0, to: 1, go: [0.43, 0.53], via: [[1.4, 0.45, 0], [2.5, 0.35, 0], [3.6, 0.45, 0]], hops: 0 },
  { from: 1, to: 2, go: [0.75, 0.84], via: [[5, 0.4, 1.3], [5, -0.6, 2.4], [5, -1.6, 3.5]], hops: 4 },
  { from: 1, to: 3, go: [0.76, 0.85], via: [[6.4, 0.5, 0], [7.5, 1.4, 0], [8.6, 2.4, 0]], hops: 4 },
];
/** 跳着走时一跳多高。 */
const COPY_HOP = 0.35;

/** 第 5 幕里冒出来的一句话：制作人发给她的那一句（producer）、她头上的「思考中」（thinking）、她说的话（said），
 * 和她的记忆柱上冒出的「想起 1 条记忆 · 来自真乃」（recalled）。 */
export type Line = {
  kind: "producer" | "thinking" | "said" | "recalled";
  /** 谁的（第几座岛）：制作人那一句算发给的那一位的。 */
  island: number;
  /** `${kind}-${island}`：DOM 上那句话的 data-lp-line。 */
  key: string;
  /** 从 show[0] 开始淡入，到 show[1] 淡出完。 */
  show: readonly [number, number];
};
const line = (kind: Line["kind"], island: number, show: readonly [number, number]): Line => ({ kind, island, key: `${kind}-${island}`, show });
/** 几句话，按出现的顺序（原型的时刻）：DOM 上、读屏器、静止版式都按这个顺序排。 */
export const LINES: readonly Line[] = [
  line("producer", 0, [0.1, 0.19]),
  line("thinking", 0, [0.185, 0.225]),
  line("said", 0, [0.225, 0.3]),
  line("recalled", 1, [0.535, 0.6]),
  line("said", 1, [0.56, 0.66]),
  line("recalled", 2, [0.845, 0.89]),
  line("recalled", 3, [0.855, 0.9]),
  line("said", 2, [0.875, 0.985]),
  line("said", 3, [0.885, 0.985]),
];
/** 淡入、淡出各占这么长。 */
const LINE_EASE = 0.012;
/** 最后一句淡入的那一段。 */
const CLOSING_IN: readonly [number, number] = [0.9, 0.95];
/** 气泡的锚点在她脚底上方这么高：身高（memory.ts 的 FIGURE_HEIGHT）上面再空一点。 */
const OVERHEAD = 1.95;
/** 制作人那句的锚点在消息上方这么高；「想起」标签的锚点在柱顶那块的顶上再高这么多。 */
const ABOVE_MESSAGE = 0.3;
const ABOVE_BLOCK = 0.12;

/** 演员是这几位（Actor.island）时有哪几句：发送的人不在时一句都没有；某位没收到，她的「想起」和她的话都没有。 */
export const linesOf = (cast: readonly number[]): Line[] => LINES.filter((l) => cast.includes(0) && cast.includes(l.island));

/** 这句话（Line 的 key，或者最后一句 `closing`）完整显示的时刻：页内查找找到它时滚到这里。 */
export function lineShownAt(key: string): number {
  if (key === "closing") return (CLOSING_IN[1] + 1) / 2;
  const l = LINES.find((l) => l.key === key);
  return l ? (l.show[0] + l.show[1]) / 2 : 0;
}
/** 收尾时连起柱顶的几根光线（两头的岛）。 */
export const THREADS: readonly (readonly [number, number])[] = [
  [0, 1],
  [1, 2],
  [1, 3],
  [0, 2],
  [0, 3],
];

/** 一条路线：按 `points` 走的向心 Catmull-Rom 曲线，按弧长取点（u 从 0 到 1 匀速走完）。 */
function route(points: readonly Vec3[]): (u: number) => Vec3 {
  const sub = (a: Vec3, b: Vec3): Vec3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
  const mix = (a: Vec3, b: Vec3, ta: number, tb: number, t: number): Vec3 => {
    const k = tb === ta ? 0 : (t - ta) / (tb - ta);
    return [lerp(a[0], b[0], k), lerp(a[1], b[1], k), lerp(a[2], b[2], k)];
  };
  const len = (v: Vec3) => Math.hypot(v[0], v[1], v[2]);
  // 两头各外插一个点，曲线才经过首尾。
  const n = points.length;
  const ext = [sub(points[0], sub(points[1], points[0])), ...points, sub(points[n - 1], sub(points[n - 2], points[n - 1]))];
  const samples: Vec3[] = [];
  const PER = 48;
  for (let i = 0; i < n - 1; i++) {
    const [p0, p1, p2, p3] = ext.slice(i, i + 4);
    const t1 = Math.sqrt(len(sub(p1, p0)));
    const t2 = t1 + Math.sqrt(len(sub(p2, p1)));
    const t3 = t2 + Math.sqrt(len(sub(p3, p2)));
    for (let j = 0; j < PER; j++) {
      const t = lerp(t1, t2, j / PER);
      const a1 = mix(p0, p1, 0, t1, t);
      const a2 = mix(p1, p2, t1, t2, t);
      const a3 = mix(p2, p3, t2, t3, t);
      samples.push(mix(mix(a1, a2, 0, t2, t), mix(a2, a3, t1, t3, t), t1, t2, t));
    }
  }
  samples.push(points[n - 1]);
  const at = [0];
  for (let i = 1; i < samples.length; i++) at.push(at[i - 1] + len(sub(samples[i], samples[i - 1])));
  const total = at.at(-1)!;
  return (u) => {
    const d = clamp01(u) * total;
    let i = 1;
    while (i < at.length - 1 && at[i] < d) i++;
    return mix(samples[i - 1], samples[i], at[i - 1], at[i], d);
  };
}

const ROUTES = COPIES.map((c) => route([memoryTop(c.from), ...c.via, memoryTop(c.to)]));
/** 每块桥面、每级台阶由哪一份走过、沿哪个轴、从哪到哪：副本走到哪亮到哪。 */
const WALKED = {
  bridge: BRIDGE.map((x) => ({ copy: 0, axis: 0, from: TURNTABLE[0] + x - 0.5, to: TURNTABLE[0] + x + 0.5 })),
  steps: STEPS.map((s) => {
    const axis = s.stair === 0 ? 2 : 0;
    return { copy: s.stair + 1, axis, from: s.center[axis] - s.size[axis] / 2, to: s.center[axis] + s.size[axis] / 2 };
  }),
};

/** 收到时一跳一压：从 `a` 开始的一个鼓包，0 到 1 到 0。 */
const hop = (a: number, p: number) => (p > a && p < a + 0.035 ? Math.sin(((p - a) / 0.035) * Math.PI) : 0);
/** 从 `up` 那一段升到 1、在 `down` 那一段落回 0。 */
const during = (up: readonly [number, number], down: readonly [number, number], p: number) =>
  smooth(up[0], up[1], p) * (1 - smooth(down[0], down[1], p));

/** 一位小人的动作。 */
export type FigurePose = {
  /** 站在哪座岛上。 */
  island: number;
  /** 收到时跳一下，0 到 1。 */
  hop: number;
  /** 真乃伸手接住时往后仰，0 到 1。 */
  reach: number;
  /** 面朝的方位（弧度，0 朝 +z，和镜头的方位角同一个量法）：平时朝着镜头，传话时转向对方。 */
  yaw: number;
};

/** 第 5 幕里这件事传到了哪一步。 */
export type MemoryStory = {
  /** 当前在第几拍（BEATS 的下标）。 */
  beat: number;
  /** 天上的手机亮到什么程度，0 到 1：消息发出来的那一刻亮。 */
  phone: number;
  /** 制作人的消息：从手机落到真乃头顶，`morph` 从 0（深蓝气泡）到 1（她颜色的方块），再收进她的柱子。
   * 没发出来、已经收进去时是 null。 */
  message: { position: Vec3; morph: number } | null;
  /** 转台的转角（弧度）：π/2 时桥面横着、没接上，转到 0 接上两边。 */
  turntable: number;
  /** 转台旁「temperature 0.7」的不透明度：转台转的那一段里一闪而过。 */
  temperature: number;
  /** 背景的 embedding 星图上发送那一位颜色的那颗点亮到什么程度，0 到 1：她收进记忆柱时亮起来，之后一直亮着。 */
  embedding: number;
  /** 两块桥面（BRIDGE 的顺序）被副本走过、亮起她颜色的程度，0 到 1。 */
  bridge: number[];
  /** 每级台阶（STEPS 的顺序）：升起来的程度和被副本走过、亮起的程度，都是 0 到 1。 */
  steps: { rise: number; lit: number }[];
  /** 正在路上的副本：到哪座岛去、现在在哪。 */
  copies: { to: number; position: Vec3 }[];
  /** 已经收进记忆柱的那几座岛：柱顶留着一块她的颜色；`flash` 是刚收进时柱灯闪成她颜色的程度。 */
  stored: { island: number; flash: number }[];
  /** 在场的几位的动作。 */
  figures: FigurePose[];
  /** 连起柱顶的光线：两头的岛和不透明度。只连已经在场的几位。 */
  threads: { from: number; to: number; opacity: number }[];
  /** 在场的几句话（linesOf，LINES 的顺序）：锚点是气泡底边中点的世界坐标（跟着说话的人的头顶、她的记忆柱、
   * 制作人的消息），不透明度只在它那一段里不是 0。 */
  lines: { key: string; anchor: Vec3; opacity: number }[];
  /** 最后一句「她们会记住你的事情……」的不透明度。 */
  closing: number;
};

/**
 * 幕内进度 p 时这件事传到了哪一步；`camera` 是这一刻的镜头（memory.ts 的 cameraAt），小人平时朝着它。`cast` 是在场的
 * 演员站在哪几座岛上（Actor.island）：某位不在时，传给她的那一份、她收进柱子、她的动作和连到她的线都没有，其他照常；
 * 发送的人（第 0 座岛）不在时，什么都不传，只剩布景。
 */
export function storyAt(p: number, camera: MemoryCamera, cast: readonly number[]): MemoryStory {
  // 发送的人在场，消息才发得出来；某位收得到，要发送的人和她都在场。
  const sends = cast.includes(0);
  const receives = (k: number) => sends && cast.includes(k);
  const beat = BEATS.findLastIndex((b) => p >= b.at);

  // 消息：从手机落到她头顶（中途往上鼓一点），变成方块，再收进柱子。
  const fall = smooth(0.09, 0.17, p);
  const store = smooth(0.22, 0.28, p);
  const [x, y, z] = lerp3(lerp3(PHONE, CATCH, fall), memoryTop(0), store);
  const position: Vec3 = [x, y + Math.sin(fall * Math.PI) * 0.4 + Math.sin(store * Math.PI) * 0.5, z];
  const message = sends && p > 0.085 && p < STORED_AT[0] ? { position, morph: smooth(0.18, 0.22, p) } : null;

  // 副本：沿路线匀速走，下台阶、上台阶时一级跳一下。
  const going = COPIES.map((c, k) => {
    const u = smooth(c.go[0], c.go[1], p);
    const [x, y, z] = ROUTES[k](u);
    return { u, at: [x, y + Math.abs(Math.sin(u * Math.PI * c.hops)) * COPY_HOP, z] as Vec3, path: [x, y, z] as Vec3 };
  });
  const copies = COPIES.flatMap((c, k) =>
    receives(c.to) && p > c.go[0] - 0.01 && p < STORED_AT[c.to] ? [{ to: c.to, position: going[k].at }] : [],
  );
  const walked = (w: { copy: number; axis: number; from: number; to: number }) =>
    receives(COPIES[w.copy].to) ? smooth(w.from, w.to, going[w.copy].path[w.axis]) : 0;

  const rise = (p - 0.64) / 0.09;
  const steps = STEPS.map((s, i) => ({ rise: smooth(s.delay, s.delay + 0.5, rise), lit: walked(WALKED.steps[i]) }));

  const stored = STORED_AT.flatMap((at, k) =>
    receives(k) && p >= at ? [{ island: k, flash: smooth(at, at + 0.015, p) * (1 - smooth(at + 0.03, at + 0.08, p)) }] : [],
  );

  // 动作：收到时一跳，真乃接住时往后仰；传话时转向对方（weight 从 0 到 1 转过去）。
  const toward = (k: number, to: Vec3 | null, weight: number) => {
    if (!to || weight === 0) return camera.azimuth;
    const want = Math.atan2(to[0] - STANDS[k][0], to[2] - STANDS[k][2]);
    return camera.azimuth + Math.atan2(Math.sin(want - camera.azimuth), Math.cos(want - camera.azimuth)) * weight;
  };
  // 果穗传话时朝着在场的那一位，两位都在时朝着两人中间。
  const [fuyuko, kiriko] = [receives(2) ? STANDS[2] : null, receives(3) ? STANDS[3] : null];
  const listeners = fuyuko && kiriko ? lerp3(fuyuko, kiriko, 0.5) : (fuyuko ?? kiriko);
  const yaw = [
    toward(0, receives(1) ? STANDS[1] : null, during([0.4, 0.44], [0.54, 0.58], p)),
    p < 0.6 ? toward(1, STANDS[0], during([0.48, 0.52], [0.56, 0.6], p)) : toward(1, listeners, during([0.72, 0.75], [0.86, 0.9], p)),
    toward(2, STANDS[1], during([0.72, 0.76], [0.85, 0.88], p)),
    toward(3, STANDS[1], during([0.72, 0.76], [0.86, 0.89], p)),
  ];
  const hops = [hop(0.165, p), hop(STORED_AT[1], p), hop(STORED_AT[2] - 0.005, p), hop(STORED_AT[3] - 0.005, p)];
  const figures = cast.map((k) => ({
    island: k,
    hop: receives(k) ? hops[k] : 0,
    reach: k === 0 ? during([0.13, 0.17], [0.2, 0.23], p) : 0,
    yaw: receives(k) ? yaw[k] : camera.azimuth,
  }));

  const anchorOf = (l: Line): Vec3 => {
    if (l.kind === "producer") return [x, position[1] + ABOVE_MESSAGE, z];
    if (l.kind === "recalled") {
      const [bx, by, bz] = memoryTop(l.island);
      return [bx, by + BLOCK / 2 + ABOVE_BLOCK, bz];
    }
    const [sx, sy, sz] = STANDS[l.island];
    return [sx, sy + OVERHEAD, sz];
  };
  const lines = linesOf(cast).map((l) => ({
    key: l.key,
    anchor: anchorOf(l),
    opacity: smooth(l.show[0], l.show[0] + LINE_EASE, p) * (1 - smooth(l.show[1] - LINE_EASE, l.show[1], p)),
  }));

  const glow = 0.75 * smooth(0.87, 0.93, p);
  return {
    beat,
    phone: sends ? smooth(0.07, 0.1, p) * (1 - smooth(0.16, 0.2, p)) : 0,
    message,
    turntable: lerp(Math.PI / 2, 0, smooth(0.31, 0.4, p)),
    temperature: smooth(0.295, 0.31, p) * (1 - smooth(0.43, 0.46, p)),
    embedding: sends ? smooth(STORED_AT[0] - 0.01, STORED_AT[0] + 0.02, p) : 0,
    bridge: WALKED.bridge.map(walked),
    steps,
    copies,
    stored,
    figures,
    threads: THREADS.flatMap(([a, b]) => (receives(a) && receives(b) ? [{ from: a, to: b, opacity: glow }] : [])),
    lines,
    closing: smooth(CLOSING_IN[0], CLOSING_IN[1], p),
  };
}
