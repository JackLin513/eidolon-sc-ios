"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";

import { BAR_INK } from "@/components/play/bar/ink";

/** A stretch of text in one color. */
export type PixelRun = { text: string; color?: string };

/** 「缝合像素」12px: its glyphs sit on whole pixels only at 12. */
const SIZE = 12;
/** Drawn at twice the logical size: some of its glyphs (键、移、除、她…) were filled in from other
 * sizes and sit on half pixels at 12, grey once drawn; at 2× they land on whole ones. */
const OVERSAMPLE = 2;
const FAMILY = '"BarFusionPixel", monospace';

/** Loads 「缝合像素」 (only the bar's page has it), so that what is measured is measured in it. */
export function loadPixelFont(): Promise<unknown> {
  return document.fonts.load(`${SIZE}px ${FAMILY}`, "あ中a");
}

let measuring: CanvasRenderingContext2D | null = null;

/** How wide `text` is drawn, in logical pixels, a character at a time as `PixelText` draws it
 * (lib/barText lays out the text box by it). */
export function measurePixelText(text: string): number {
  measuring ??= document.createElement("canvas").getContext("2d");
  if (!measuring) return [...text].length * SIZE;
  measuring.font = `${SIZE}px ${FAMILY}`;
  let width = 0;
  for (const ch of text) width += measuring.measureText(ch).width;
  return width;
}

/** The advance of a character in the monospaced setting: half a square for narrow ones, a whole one
 * for CJK and other wide ones. */
function monoAdvance(ch: string): number {
  const code = ch.codePointAt(0) ?? 0;
  const isWide = code >= 0x2e80 && !(code >= 0xff61 && code <= 0xffdc);
  return isWide ? SIZE : SIZE / 2;
}

/**
 * 画面里的字（.scratch/bar-room spec「像素字」）：先在逻辑像素大小（按 2 倍）的 canvas 上用「缝合像素」12px 写，
 * 透明度二值化去掉抗锯齿，canvas 再跟着画面一起按最近邻放大，所以字和画是一个风格，手机的小数缩放下也不糊。
 * 坐标是逻辑像素，`y` 是这一行的顶，行高 `lineHeight`，字在行里竖着居中（落在整像素上）；`\n` 换行。
 * `mono`：调酒台的英文标签、份数槽里的短名，每个字占定宽（窄的半格、宽的一格）。
 * `width` 给了就是这么宽，`align` 在里面左对齐或居中；不给就是字有多宽就多宽。折行交给调用的一方（lib/barText）。
 */
export function PixelText({
  x,
  y,
  runs,
  color = BAR_INK.text,
  lineHeight = 16,
  width,
  align = "left",
  mono = false,
  label,
}: {
  x: number;
  y: number;
  runs: PixelRun[] | string;
  color?: string;
  lineHeight?: number;
  width?: number;
  align?: "left" | "center";
  mono?: boolean;
  /** What a screen reader says; the text itself when not given. Empty to hide it. */
  label?: string;
}) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const list: PixelRun[] = typeof runs === "string" ? [{ text: runs }] : runs;
  const key = JSON.stringify(list);
  const text = list.map((run) => run.text).join("");
  const [box, setBox] = useState({ width: width ?? 0, height: lineHeight });
  const [fontsLoaded, setFontsLoaded] = useState(0);

  // 字体载入之前画的是退回的字体：载入后重画一次。
  useEffect(() => {
    let live = true;
    void document.fonts.load(`${SIZE}px ${FAMILY}`, text || "a").then(() => live && setFontsLoaded((n) => n + 1));
    return () => {
      live = false;
    };
  }, [text]);

  useLayoutEffect(() => {
    const c = canvas.current;
    const ctx = c?.getContext("2d", { willReadFrequently: true });
    if (!c || !ctx) return;
    ctx.font = `${SIZE}px ${FAMILY}`;
    const advance = (ch: string) => (mono ? monoAdvance(ch) : ctx.measureText(ch).width);
    const lines: { ch: string; color: string }[][] = [[]];
    for (const run of list) {
      for (const ch of run.text) {
        if (ch === "\n") lines.push([]);
        else lines[lines.length - 1].push({ ch, color: run.color ?? color });
      }
    }
    const widths = lines.map((line) => line.reduce((sum, glyph) => sum + advance(glyph.ch), 0));
    const w = width ?? Math.ceil(Math.max(...widths, 1));
    const h = lines.length * lineHeight;
    if (c.width !== w * OVERSAMPLE || c.height !== h * OVERSAMPLE) {
      c.width = w * OVERSAMPLE;
      c.height = h * OVERSAMPLE;
    }
    if (box.width !== w || box.height !== h) setBox({ width: w, height: h });
    ctx.setTransform(OVERSAMPLE, 0, 0, OVERSAMPLE, 0, 0);
    ctx.clearRect(0, 0, w, h);
    ctx.font = `${SIZE}px ${FAMILY}`;
    // 顶端对齐到整像素：点阵正好落在格子上（居中基线会落在半像素上，二值化后笔画发粗）。
    ctx.textBaseline = "top";
    lines.forEach((line, row) => {
      let cx = align === "center" ? Math.round((w - widths[row]) / 2) : 0;
      const cy = row * lineHeight + Math.round((lineHeight - SIZE) / 2);
      for (const glyph of line) {
        ctx.fillStyle = glyph.color;
        ctx.fillText(glyph.ch, cx, cy);
        cx += advance(glyph.ch);
      }
    });
    // 去掉抗锯齿：透明度过半的全不透明，其余全透明。
    const image = ctx.getImageData(0, 0, c.width, c.height);
    const data = image.data;
    for (let i = 3; i < data.length; i += 4) data[i] = data[i] >= 128 ? 255 : 0;
    ctx.putImageData(image, 0, 0);
    // `key` stands for the runs, a new array on every render.
  }, [key, color, lineHeight, width, align, mono, fontsLoaded, box.width, box.height]);

  return (
    <canvas
      ref={canvas}
      role={label === "" ? undefined : "img"}
      aria-label={label === "" ? undefined : (label ?? text)}
      aria-hidden={label === "" ? true : undefined}
      className="pointer-events-none absolute"
      style={{ left: x, top: y, width: box.width, height: box.height }}
    />
  );
}
