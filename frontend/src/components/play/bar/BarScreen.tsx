"use client";

import { createContext, type CSSProperties, useContext, useEffect, useRef, useState, type ReactNode } from "react";

import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";
import { barImage, Sprite } from "@/components/play/bar/Sprite";
import { copy } from "@/i18n";
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
export function usePointer(): BarPointer {
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

/** Where each of the original's gloves points (its hot spot), at 1×. */
const HOT_SPOTS = { spr: [4, 0], clicked: [4, 0], open: [4, 0], closed: [9, 0], next: [4, 0] } as const;

/**
 * 原版的鼠标（cursor_obj，照原型的 `cursorVars`）：平时白手套、按下时「按下」，停在材料上张开（`--cur-open`）、拖着时握拳
 * （`--cur-closed`），停在文本框上是会动的 NEXT 气泡（`--cur-next-0`…`3`）。原版鼠标跟着画面放大，这里按缩放取整选
 * 1/2/3 倍的图，热点也跟着乘。画面里的按钮继承画面的鼠标，要换的地方自己写 `cursor: var(--cur-…)`。
 */
function gloveCursors(scale: number, isPressed: boolean): CSSProperties {
  const k = Math.min(3, Math.max(1, Math.round(scale)));
  const glove = (name: string, spot: keyof typeof HOT_SPOTS) =>
    `url(${barImage(`cur_${name}@${k}`)}) ${HOT_SPOTS[spot][0] * k} ${HOT_SPOTS[spot][1] * k}, auto`;
  const vars: Record<string, string> = {
    cursor: "var(--cur)",
    "--cur": isPressed ? glove("clicked", "clicked") : glove("spr", "spr"),
    "--cur-open": glove("open", "open"),
    "--cur-closed": glove("closed", "closed"),
  };
  for (let i = 0; i < 4; i++) vars[`--cur-next-${i}`] = glove(`next_${i}`, "next");
  return vars as CSSProperties;
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
 * 再上面是按钮和文字（`children`），开着扫描线时（`scanlines`，设置里的）整块画面最上面盖原版的扫描线（隔一行压暗）。
 * 手机竖着时整层盖上「请横过来」（`portrait`），下面的画面照旧在。
 * 电脑（细指针）上鼠标是原版的手套（`gloveCursors`），手机上没有。
 */
export function BarScreen({
  room,
  guest,
  book,
  portrait,
  scanlines,
  children,
}: {
  room: ReactNode;
  guest?: ReactNode;
  book?: ReactNode;
  portrait: ReactNode;
  scanlines: boolean;
  children: ReactNode;
}) {
  const layer = useRef<HTMLDivElement>(null);
  const probe = useRef<HTMLDivElement>(null);
  const pointer = usePointer();
  const [placed, setPlaced] = useState<BarPlacement | null>(null);
  const [isPressed, setPressed] = useState(false);
  useEffect(() => {
    if (!isPressed) return;
    const release = () => setPressed(false);
    window.addEventListener("pointerup", release);
    window.addEventListener("pointercancel", release);
    return () => {
      window.removeEventListener("pointerup", release);
      window.removeEventListener("pointercancel", release);
    };
  }, [isPressed]);

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
              ...(pointer === "fine" ? gloveCursors(placed.scale, isPressed) : {}),
            }}
            onPointerDown={() => setPressed(true)}
          >
            {room}
            {guest}
            {book}
            <Sprite name="frame" x={0} y={0} width={BAR_WIDTH} height={BAR_HEIGHT} />
            {children}
            {scanlines && <Sprite name="scanlines" x={0} y={0} width={BAR_WIDTH} height={BAR_HEIGHT} />}
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
  cursor,
  pressed,
  onClick,
}: {
  x: number;
  y: number;
  width: number;
  height: number;
  label: string;
  /** Its own pointer, over the screen's (a `var(--cur-…)` glove). */
  cursor?: string;
  /** A switch's state, for screen readers. */
  pressed?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      aria-pressed={pressed}
      className="bar-hit absolute"
      style={{ left: x, top: y, width, height, cursor }}
      onClick={onClick}
    />
  );
}

/** The side menu's four cells, as the original's: 「设置」 and 「读取」 above, 「点唱机」 and 「退出」 below,
 * each 72×20, the word 5 px in. */
const CELLS = { settings: [445, 279], fullscreen: [543, 279], cell: [445, 312], leave: [543, 312] } as const;
const CELL = { width: 72, height: 20 };

/** A cell of the side menu: its word and color, whether it is on (a switch, for screen readers), and
 * what a tap does (null: grey, no tap). */
export type MenuCell = { label: string; color: string; pressed?: boolean; onClick: (() => void) | null };

const JUKEBOX_INK = { open: BAR_INK.lit, closed: BAR_INK.text, none: BAR_INK.off } as const;

/** 「点唱机」 in the side menu: lit while the small player is open, grey with no audio. */
export function jukeboxCell(state: "open" | "closed" | "none", onToggle: () => void): MenuCell {
  return {
    label: copy.bar.jukebox.name,
    color: JUKEBOX_INK[state],
    pressed: state === "open",
    onClick: state === "none" ? null : onToggle,
  };
}

function MenuItem({ at, cell }: { at: readonly [number, number]; cell: MenuCell }) {
  const [x, y] = at;
  return (
    <>
      <PixelText x={x + 5} y={y + 1} runs={cell.label} color={cell.color} label={cell.onClick ? "" : cell.label} />
      {cell.onClick && <HitArea x={x} y={y} {...CELL} label={cell.label} pressed={cell.pressed} onClick={cell.onClick} />}
    </>
  );
}

/** The original's side menu, under the bar counter, in the original's places (.scratch/bar-room 票 14):
 * 「设置」 (`settings`) and 「全屏」 or 「窗口」 (`fullscreen`, where the original has 「读取」) above,
 * a cell (`cell`: 「点唱机」, or 「跳过」 through the tutorial) and 「离开」 below; any but 「离开」 not
 * there at all when null (at the door; 「全屏」 where the browser cannot go full screen). No hover. */
export function SideMenu({
  settings,
  fullscreen,
  cell,
  leave,
  onLeave,
}: {
  settings: MenuCell | null;
  fullscreen: MenuCell | null;
  cell: MenuCell | null;
  leave: string;
  onLeave: () => void;
}) {
  return (
    <>
      {settings && <MenuItem at={CELLS.settings} cell={settings} />}
      {fullscreen && <MenuItem at={CELLS.fullscreen} cell={fullscreen} />}
      {cell && <MenuItem at={CELLS.cell} cell={cell} />}
      <MenuItem at={CELLS.leave} cell={{ label: leave, color: BAR_INK.text, onClick: onLeave }} />
    </>
  );
}
