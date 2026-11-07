// 整页的时间线：每一幕占几屏滚动，页面上分成哪几段。落地页模型（scene.ts）按它判断滚到了哪一幕，
// 页面按它定每一段的高度（Landing.tsx），舞台的循环按它把滚动位置换算成屏数（LightStage.tsx）。
//
// 单位是「屏」：滚过一个视口高度是一屏。页面上的一段要么钉住（`position: sticky` 的舞台，滚动驱动
// 画面变形，高度正好是 screens 个视口），要么照常往上走（第 0 幕、第 6 幕，高度由内容决定，按比例
// 换算成 screens 屏）。钉住的一段比它的几幕多一屏：舞台解开钉住、往上走，下一段同时从下面进来。

/** 第 1 幕「分光」钉住滚过几屏。 */
export const ACT1_SCREENS = 3.2;
/** 第 2 幕「光谱」：扇面拉直、归队成组合顺序，再放大到横滚的轨道上，然后每个组合一段（停留加整页推入），
 * 最后一个组合多停一会儿。 */
export const REGROUP_SCREENS = 1;
export const ZOOM_SCREENS = 0.9;
export const SEG_SCREENS = 1.5;
export const TAIL_SCREENS = 0.4;
/** 第 3 幕「她说日语」：她说几句日语，竖排的原文一列列出来，中文字幕一句句被光扫出来。 */
export const ACT3_SCREENS = 2.4;
/** 第 4 幕「来电」：她的光收成一条竖线、变成一台手机的侧边，手机转过背面、转到正面，亮屏、来电，跟着铃声
 * 振动；接听由访客点决定，不随滚动。转身要滚得慢一点才看得清，所以占得长。 */
export const ACT4_SCREENS = 3.2;
/** 第 5 幕「记忆」：3D 的夜空里，一件事从一位偶像传到另一位、再传开；镜头随滚动推近、拉远、转向（原型的长度）。 */
export const ACT5_SCREENS = 8;
/** 第 6 幕「诚实事项」照常往上走，按这么多屏换算：最后一屏是第 7 幕进来的时候。 */
export const ACT6_SCREENS = 1.6;
/** 第 7 幕「开始」：28 道光收拢成一块手机屏幕的白光。 */
export const ACT7_SCREENS = 2;

export type ActSpan = {
  act: number;
  /** 从第几屏开始。 */
  from: number;
  /** 幕内进度从 0 走到 1 要滚过几屏。 */
  length: number;
  /** 下一幕从这里开始：钉住的一段的最后一幕，比 from + length 多出解开钉住的那一屏。 */
  to: number;
};

/** 页面上的一段（Landing.tsx 里一个 `data-lp-section` 元素）。 */
export type Section = {
  /** 第几段，从 0 起：页面上的元素用 `data-lp-section` 标出它。 */
  index: number;
  acts: readonly number[];
  from: number;
  /** 这一段占几屏。钉住的一段高度正好是这么多个视口。 */
  screens: number;
  pinned: boolean;
};

export type Timeline = { acts: ActSpan[]; sections: Section[] };

/** `unitCount`：光谱里有几个组合。没有角色时没有光谱，也没有她说日语、来电这两幕。 */
export function timelineOf(unitCount: number): Timeline {
  const spectrum = unitCount > 0 ? REGROUP_SCREENS + ZOOM_SCREENS + unitCount * SEG_SCREENS + TAIL_SCREENS : 0;
  const plan: { acts: [act: number, length: number][]; pinned: boolean }[] = [
    { acts: [[0, 1]], pinned: false },
    { acts: spectrum > 0 ? [[1, ACT1_SCREENS], [2, spectrum]] : [[1, ACT1_SCREENS]], pinned: true },
    ...(spectrum > 0 ? [{ acts: [[3, ACT3_SCREENS], [4, ACT4_SCREENS]] as [number, number][], pinned: true }] : []),
    { acts: [[5, ACT5_SCREENS]], pinned: true },
    { acts: [[6, ACT6_SCREENS]], pinned: false },
    { acts: [[7, ACT7_SCREENS]], pinned: true },
  ];
  const acts: ActSpan[] = [];
  const sections: Section[] = [];
  let at = 0;
  for (const { acts: parts, pinned } of plan) {
    const from = at;
    parts.forEach(([act, length], k) => {
      const release = pinned && k === parts.length - 1 ? 1 : 0;
      acts.push({ act, from: at, length, to: at + length + release });
      at += length + release;
    });
    sections.push({ index: sections.length, acts: parts.map(([act]) => act), from, screens: at - from, pinned });
  }
  return { acts, sections };
}

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));

/** 滚过 `scroll` 屏时在哪一幕、幕内进度。 */
export function whereIs(timeline: Timeline, scroll: number): { act: number; actProgress: number } {
  const span = timeline.acts.find((a) => scroll < a.to) ?? timeline.acts.at(-1)!;
  return { act: span.act, actProgress: clamp01((scroll - span.from) / span.length) };
}

/** 第 `act` 幕。 */
export const spanOf = (timeline: Timeline, act: number): ActSpan | undefined => timeline.acts.find((a) => a.act === act);

/** 第 2 幕里第 u 个组合停稳的地方（屏）：放大以后，这个组合那一段的开头再往里一点。按组合跳转滚到这里。 */
export function holdAt(timeline: Timeline, u: number): number {
  const act2 = spanOf(timeline, 2);
  return act2 ? act2.from + REGROUP_SCREENS + ZOOM_SCREENS + u * SEG_SCREENS + 0.05 : 0;
}

/** 每一幕停稳的地方（幕内进度）：第 3 幕几句话都说完，第 4 幕来电的画面显出来，第 5 幕开头的全景（标题和正文
 * 只在这时显示），第 7 幕行动按钮出现。 */
const REST: Partial<Record<number, number>> = { 3: 0.95, 4: 0.8, 5: 0, 7: 1 };

/**
 * 第 `act` 幕停稳的地方（屏）：键盘聚焦到别的幕里的按钮时滚到这里，按钮在画面上、看得见。
 * 第 2 幕是第一个组合停稳的地方；这一幕不在时间线上（没有角色时没有第 2 到 4 幕）时没有。
 */
export function restAt(timeline: Timeline, act: number): number | undefined {
  if (act === 2) return spanOf(timeline, 2) && holdAt(timeline, 0);
  const span = spanOf(timeline, act);
  return span && span.from + span.length * (REST[act] ?? 0.5);
}
