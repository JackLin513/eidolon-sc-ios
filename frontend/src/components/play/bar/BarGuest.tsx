"use client";

import { useMemo, useState } from "react";

import { Stand } from "@/components/conversations/stand/Stand";
import { useStandOutfits } from "@/components/conversations/useStandOutfits";
import { useMediaQuery } from "@/hooks/useMediaQuery";
import type { Character } from "@/lib/api";
import type { Emotion } from "@/lib/standAnimations";
import { cn } from "@/lib/utils";

/** The guest's window, cut out of the frame (the prototype's clip of her), and her stand in it: the
 * one guest's place, its middle at x 185, down to her waist. */
const WINDOW = { x: 19, y: 27, width: 410, height: 241 };
const STAND = { x: 45, width: 280 };

/**
 * 客人立绘（.scratch/bar-room spec「立绘」）：通话层的 Spine 立绘（`Stand`），穿她选中的衣装（同通话层的 `outfitsToTry`），
 * 情绪照她正在说的那句换动作，她的句子打字时开口。立绘在放大的画面里，画布按布局尺寸（就是逻辑像素）画，
 * 像素比压到 1，再跟着画面按最近邻放大，看起来是像素画。裁在客人窗里，到腰。
 * 进门先是黑色剪影淡入，再淡成彩色，各约 0.5 秒、每次加 1/4（调研笔记「立绘的入场退场」，bar.css 的 `.bar-guest-in`）。
 * 加载不到时什么都不画，客人窗里只剩吧台背景。
 */
export function BarGuest({ character, mood, speaking }: { character: Character; mood: Emotion; speaking: boolean }) {
  const outfits = useStandOutfits(character);
  const isReducedMotion = useMediaQuery("(prefers-reduced-motion: reduce)", false);
  const [isLoaded, setLoaded] = useState(false);
  // 同样的指令给同一个对象：每次重画都给新的，立绘会以为她换了样子。
  const direction = useMemo(() => ({ mood, speaking, looking: true, nod: null }), [mood, speaking]);
  if (!outfits) return null;
  return (
    <div className="pointer-events-none absolute overflow-hidden" style={{ left: WINDOW.x, top: WINDOW.y, width: WINDOW.width, height: WINDOW.height }}>
      <div
        className={cn("absolute top-0 h-full", isLoaded ? "bar-guest-in" : "opacity-0")}
        style={{ left: STAND.x - WINDOW.x, width: STAND.width }}
      >
        <Stand
          outfits={outfits.toTry}
          framing="waist"
          isPaused={false}
          entrance="none"
          direction={direction}
          isReducedMotion={isReducedMotion}
          maxPixelRatio={1}
          onTried={(_, loaded) => loaded && setLoaded(true)}
        />
      </div>
    </div>
  );
}
