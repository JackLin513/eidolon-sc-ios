// 舞台的循环（LightStage）和各幕的 DOM（Spectrum、Call、幕名轨）之间传的几样东西。循环每帧算画面、
// 直接写样式，不走 React 状态；只有偶尔才变的（当前在哪一幕、当前组合、该挂立绘的人）经这里通知 React。
// 静止版式里没有循环，当前在哪一幕由幕名轨（Rail）按页面上哪一幕在视口中间来定。反过来，访客聚焦到谁、
// 按组合跳转、滚到某一幕，由各幕写在这里，循环下一帧读到。

import { useEffect, useState, useSyncExternalStore } from "react";

import type { Tier } from "./model/tier";

export type StageSnapshot = {
  /** 当前在哪一幕（落地页模型的 `act`）。 */
  act: number;
  /** 第 2 幕当前的组合。 */
  unit: number;
  /** 该挂立绘的那一位（落地页模型的 `spectrum.stand`）。 */
  stand: string | null;
};

type Listener = () => void;

let snapshot: StageSnapshot = { act: 0, unit: 0, stand: null };
const listeners = new Set<Listener>();

export const stageStore = {
  get: (): StageSnapshot => snapshot,
  /** 只有真的变了才通知。 */
  set(next: Partial<StageSnapshot>) {
    if (Object.entries(next).every(([k, v]) => snapshot[k as keyof StageSnapshot] === v)) return;
    snapshot = { ...snapshot, ...next };
    listeners.forEach((l) => l());
  },
  subscribe(listener: Listener) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  /** 访客聚焦到的偶像：指针移上去、键盘聚焦、手指点。循环据此让她的光和背景淡入。 */
  focus: null as string | null,
  /** 滚到第 u 个组合停稳的地方；运动版式的循环挂上它，`instant` 时不带过渡（键盘聚焦到别的组合时）。 */
  jump: null as ((unit: number, instant?: boolean) => void) | null,
  /**
   * 立即滚到第 `act` 幕停稳的地方（键盘聚焦到别的幕里的按钮时），或者这一幕的幕内进度 `progress` 处（页内查找
   * 找到一句只在某个时刻才显示的字幕时）；运动版式的循环挂上它。
   */
  goto: null as ((act: number, progress?: number) => void) | null,
};

/** 当前在哪一幕、哪个组合、该挂立绘的人（偶尔才变）。 */
export const useStage = (): StageSnapshot => useSyncExternalStore(stageStore.subscribe, stageStore.get, stageStore.get);

/** 首屏前定好的版式和档位（tierScript.ts 写在 <html> 上），以及是不是手指操作的设备。 */
export type Layout = { motion: boolean; tier: Tier; touch: boolean };

/** 水合以后才读得到：服务端不知道访客的设备，水合之前是 null，各幕先按没有 JS 的样子渲染。 */
export function useLayout(): Layout | null {
  const [layout, setLayout] = useState<Layout | null>(null);
  useEffect(() => {
    const html = document.documentElement;
    setLayout({
      motion: html.dataset.lpLayout === "motion",
      tier: (html.dataset.lpTier as Tier | undefined) ?? "static",
      touch: matchMedia("(hover: none)").matches,
    });
  }, []);
  return layout;
}
