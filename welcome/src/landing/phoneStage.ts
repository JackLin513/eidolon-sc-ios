// 第 4 幕手机这一层的起落（LightStage 的循环每帧调 frame）：第 3、4 幕那一段按需建画布、离开就不画、手指操作的
// 设备上离远了放掉上下文（canvasStage.ts）；有手机的那一刻才画，画面没变就不画。画布丢了上下文、建不起来，就收起
// 手机，换成事先渲染好的手机图，不连带落地页降档。
//
// 手机画好第一帧以后，.lp-root 加上 lp-phone-on：屏幕下面不再垫事先渲染好的手机图（landing.css）。收起时拿掉。

import { createCanvasStage } from "./canvasStage";
import type { PhoneState } from "./model/phone";
import type { Quality } from "./model/tier";
import { spanOf, type Timeline } from "./model/timeline";

export type PhoneStage = {
  /** 每帧调：`scroll` 是滚过的屏数，`phone` 是落地页模型这一帧的手机（不在第 4 幕时是 null）。 */
  frame(scroll: number, phone: PhoneState | null): void;
  resize(w: number, h: number): void;
  setQuality(quality: Quality): void;
  /** 收起手机（落地页退到静态档、卸载）：之后不再建。 */
  drop(): void;
};

export function createPhoneStage({
  root,
  host,
  timeline,
  touch,
  quality,
  glow,
}: {
  root: HTMLElement;
  /** 画布放进这里（Call 的 .lp-phone，和屏幕上的来电界面同一个容器，一起振动）。 */
  host: HTMLElement;
  timeline: Timeline;
  touch: boolean;
  quality: Quality;
  /** 屏幕亮起时的颜色：打来电话的她的颜色。 */
  glow: string;
}): PhoneStage {
  const act3 = spanOf(timeline, 3);
  const act4 = spanOf(timeline, 4);
  const setOn = (on: boolean) => root.classList.toggle("lp-phone-on", on);
  const stage =
    act3 &&
    act4 &&
    createCanvasStage({
      host,
      className: "lp-phone-canvas",
      span: [act3.from, act4.to],
      touch,
      quality,
      load: async (canvas, q) => (await import("./phoneLayer")).createPhoneLayer(canvas, q),
      onDrop: () => setOn(false),
    });

  return {
    frame(scroll, phone) {
      const layer = stage?.frame(scroll);
      if (!layer || !phone) return;
      layer.render(phone, glow);
      if (!root.classList.contains("lp-phone-on")) setOn(true);
    },
    resize: (w, h) => stage?.resize(w, h),
    setQuality: (q) => stage?.setQuality(q),
    drop: () => stage?.drop(),
  };
}
