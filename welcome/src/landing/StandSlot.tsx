"use client";

import { useEffect, useRef } from "react";

import type { Outfit } from "@/lib/api";

/**
 * 她的立绘（第 2 幕聚焦时、第 4 幕来电时）：交给 iframe 里那份页面画
 * （App 的 stand.html + stand-player.js）。上游的 React 封装在这个文档里画几帧
 * 会把网页进程带崩（#118 的排查记录），这个播放器则完全正常。
 */
export function StandSlot({
  outfit,
  speaking = false,
}: {
  outfit: Outfit;
  // 上游还会传取景、静止档、是否暂停：iframe 里的播放器自己处理这些。
  framing?: string;
  still?: boolean;
  speaking?: boolean;
  paused?: boolean;
}) {
  const frame = useRef<HTMLIFrameElement>(null);
  const speakingNow = useRef(speaking);
  speakingNow.current = speaking;
  // 换人、换衣装才换 src（会重载 iframe）；说话与否只是告诉里面，不重载。
  useEffect(() => {
    frame.current?.contentWindow?.postMessage({ type: "pose", speaking }, "*");
  }, [speaking]);
  // iframe 加载完会喊一声，把当前状态补给它（第一次的 pose 可能在它装监听器之前就发了）。
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (event.data?.type === "stand-ready") {
        frame.current?.contentWindow?.postMessage({ type: "pose", speaking: speakingNow.current }, "*");
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, []);

  return (
    <iframe
      ref={frame}
      className="lp-stand-frame"
      title=""
      src={`../stand/stand.html?outfit=${encodeURIComponent(outfit.url)}`}
      scrolling="no"
      aria-hidden
      style={{ pointerEvents: "none" }}
    />
  );
}
