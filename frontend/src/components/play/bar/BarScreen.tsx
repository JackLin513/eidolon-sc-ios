"use client";

import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";

import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";
import { Sprite } from "@/components/play/bar/Sprite";
import { BAR_HEIGHT, BAR_WIDTH, type BarPointer, type BarPlacement, barScreen } from "@/lib/barScreen";

const BarScaleContext = createContext(1);

/** How many CSS pixels a logical pixel of the screen is (the Spine stand draws at 1/this). */
export function useBarScale(): number {
  return useContext(BarScaleContext);
}

const COARSE = "(pointer: coarse)";

/** The primary pointer: a finger or a mouse. */
export function primaryPointer(): BarPointer {
  return matchMedia(COARSE).matches ? "coarse" : "fine";
}

/** The primary pointer, followed as it changes (a tablet's keyboard put on or taken off). */
function usePointer(): BarPointer {
  const [pointer, setPointer] = useState<BarPointer>("fine");
  useEffect(() => {
    const coarse = matchMedia(COARSE);
    const read = () => setPointer(primaryPointer());
    read();
    coarse.addEventListener("change", read);
    return () => coarse.removeEventListener("change", read);
  }, []);
  return pointer;
}

/** The safe-area insets, read off an element padded by them. */
function insetsOf(probe: HTMLElement) {
  const style = getComputedStyle(probe);
  const px = (value: string) => parseFloat(value) || 0;
  return {
    top: px(style.paddingTop),
    right: px(style.paddingRight),
    bottom: px(style.paddingBottom),
    left: px(style.paddingLeft),
  };
}

/**
 * 酒吧的画面（.scratch/bar-room spec「画框和缩放」）：铺满外壳里通话条下面那一块（导航栏和 dock 这一页不画，
 * lib/navShell 的 `showsNav`），不滚动；里面一块 640×360 的逻辑画面，照 lib/barScreen 放大、摆在中间
 * （扣掉安全区和通话条，通话条出现、消失时重新算）。画面里的东西都按逻辑像素摆，分五层，从下往上：
 * 吧台背景（`room`）、客人立绘（`guest`）、调酒时盖住客人的配方书（`book`）、整张不透明的外框（挖出 L 形的客人窗和文本框），
 * 最上面是按钮和文字（`children`）。手机竖着时整层盖上「请横过来」（`portrait`），下面的画面照旧在。
 */
export function BarScreen({
  room,
  guest,
  book,
  portrait,
  children,
}: {
  room: ReactNode;
  guest?: ReactNode;
  book?: ReactNode;
  portrait: ReactNode;
  children: ReactNode;
}) {
  const layer = useRef<HTMLDivElement>(null);
  const probe = useRef<HTMLDivElement>(null);
  const pointer = usePointer();
  const [placed, setPlaced] = useState<BarPlacement | null>(null);

  useEffect(() => {
    const el = layer.current;
    const padded = probe.current;
    if (!el || !padded) return;
    const measure = () => {
      const insets = insetsOf(padded);
      // 这一层从通话条底下铺到视口底：它的顶就是通话条的高。
      const callBar = Math.max(el.getBoundingClientRect().top, 0);
      setPlaced(barScreen({ width: el.clientWidth, height: callBar + el.clientHeight, insets, callBar, pointer }));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [pointer]);

  return (
    <div ref={layer} className="bar-layer absolute inset-0" style={{ background: BAR_INK.ground }}>
      <div
        ref={probe}
        aria-hidden
        className="pointer-events-none invisible absolute"
        style={{
          padding:
            "env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)",
        }}
      />
      {placed && (
        <BarScaleContext.Provider value={placed.scale}>
          <div
            className="bar-stage absolute overflow-hidden"
            style={{
              left: placed.left,
              top: placed.top,
              width: BAR_WIDTH,
              height: BAR_HEIGHT,
              transform: `scale(${placed.scale})`,
              transformOrigin: "0 0",
            }}
          >
            {room}
            {guest}
            {book}
            <Sprite name="frame" x={0} y={0} width={BAR_WIDTH} height={BAR_HEIGHT} />
            {children}
          </div>
        </BarScaleContext.Provider>
      )}
      {portrait}
    </div>
  );
}

/** A spot of the screen that does something, over what is drawn there: a label for screen readers,
 * no look of its own, no hover (the original's side menu has none). */
export function HitArea({
  x,
  y,
  width,
  height,
  label,
  onClick,
}: {
  x: number;
  y: number;
  width: number;
  height: number;
  label: string;
  onClick: () => void;
}) {
  return (
    <button type="button" aria-label={label} className="bar-hit absolute" style={{ left: x, top: y, width, height }} onClick={onClick} />
  );
}

/** The original's side menu, under the bar counter: its upper row (the original's 「设置」 and 「读取」)
 * holds the order memo (ticket 06); its lower row 「点唱机」 at (445,312) (ticket 11) and 「离开」 at
 * the original's 「退出」, (543,312), each 72×20, the word 5 px in. No hover. */
export function SideMenu({ leave, onLeave }: { leave: string; onLeave: () => void }) {
  return (
    <>
      <PixelText x={548} y={313} runs={leave} color={BAR_INK.text} label="" />
      <HitArea x={543} y={312} width={72} height={20} label={leave} onClick={onLeave} />
    </>
  );
}
