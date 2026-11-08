"use client";

import { useEffect, useRef, useState } from "react";

import { MEMORY_STILL } from "./model/memory";

/**
 * 第 5 幕事先渲染好的终局全景图（scripts/landing-memory-still.mjs，放在存储桶）：四个人、四根记忆柱顶上发送那一位颜色的
 * 方块和连线。静止版式里排在这一幕的文字上面；运动版式里平时 display: none（懒加载的图不下载），3D 画布丢了上下文、
 * 建不起来时（.lp-root 有 lp-memory-lost）摆在画面正中（landing.css）。加载不到时整个拿掉，只剩文字，不出现破图。
 */
export function MemoryStill({ src }: { src: string }) {
  const [failed, setFailed] = useState(false);
  const img = useRef<HTMLImageElement>(null);
  // 水合以前就加载失败了的话，React 接不到那次 error。
  useEffect(() => {
    const el = img.current;
    if (el?.complete && el.naturalWidth === 0) setFailed(true);
  }, []);
  if (failed) return null;
  return (
    // 不用 next/image：它不进落地页的包，图在存储桶上已经压好了。
    <img
      ref={img}
      className="lp-memory-still"
      src={src}
      alt=""
      width={MEMORY_STILL.w}
      height={MEMORY_STILL.h}
      loading="lazy"
      decoding="async"
      aria-hidden
      onError={() => setFailed(true)}
    />
  );
}
