"use client";

import { useEffect, useState } from "react";

import { HitArea } from "@/components/play/bar/BarScreen";
import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";
import { goFullscreenLandscape, useFullscreenButton } from "@/components/play/bar/PortraitGuard";
import { Sprite } from "@/components/play/bar/Sprite";
import { copy } from "@/i18n";

const t = copy.bar.door;

/** The sign over the door, where the original's neon says its name. */
const SIGN = { x: 290, y: 30, width: 56, height: 24 };
/** Android's 「全屏」 at the door, beside 「离开」 (the prototype's place). */
const FULLSCREEN = { x: 552, y: 324, width: 50, height: 24 };

/**
 * 店门口（.scratch/bar-room spec「一次营业的流程」，照原型的 `Door`）：原版 barintro 三帧霓虹闪，招牌写 VA-283；
 * 点一下进门。进不了时下面写为什么（`notice`），可以再点。安卓多一个「全屏」（同竖屏提醒的按钮）。
 */
export function BarDoor({ notice, onEnter }: { notice: string | null; onEnter: () => void }) {
  const [frame, setFrame] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setFrame((n) => (Math.random() < 0.15 ? (n + 1) % 3 : 0)), 120);
    return () => window.clearInterval(id);
  }, []);
  const isFullscreenOffered = useFullscreenButton();
  return (
    <>
      <div className="absolute inset-0" style={{ background: BAR_INK.black }} />
      <Sprite name={`intro_${frame}`} x={0} y={0} width={640} height={360} />
      <div className="absolute" style={{ left: SIGN.x, top: SIGN.y, width: SIGN.width, height: SIGN.height, background: frame === 0 ? BAR_INK.pink : BAR_INK.pinkDim }} />
      <PixelText x={SIGN.x} y={SIGN.y + 4} width={SIGN.width} align="center" runs="VA-283" label="" />
      <PixelText x={0} y={290} width={640} align="center" runs={notice ?? t.enter} color={notice ? BAR_INK.text : BAR_INK.sub} />
      <HitArea x={0} y={0} width={640} height={360} label={t.enter} onClick={onEnter} />
      {isFullscreenOffered && (
        <>
          <PixelText x={FULLSCREEN.x + 8} y={FULLSCREEN.y + 4} runs={t.fullscreen} label="" />
          <HitArea {...FULLSCREEN} label={t.fullscreen} onClick={() => void goFullscreenLandscape()} />
        </>
      )}
    </>
  );
}
