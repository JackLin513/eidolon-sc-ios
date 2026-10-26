"use client";

import { useEffect, useState } from "react";

import { HitArea } from "@/components/play/bar/BarScreen";
import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";
import { Sprite } from "@/components/play/bar/Sprite";
import { useBarFullscreen } from "@/components/play/bar/useBarFullscreen";
import { copy } from "@/i18n";

const t = copy.bar.door;

/** The sign over the door, where the original's neon says its name. */
const SIGN = { x: 290, y: 30, width: 56, height: 24 };
/** 「全屏」 and 「教程」 in a row left of 「离开」 (the side menu's lower right), each a side menu cell, the
 * word 5 px in: under the notice, which is centred and may run long. */
const ROW = { y: 312, width: 72, height: 20, right: 543 };

/**
 * 店门口（.scratch/bar-room spec「一次营业的流程」，照原型的 `Door`）：原版 barintro 三帧霓虹闪，招牌写 VA-283；
 * 点一下进门；等接口回来时（`isEntering`）下面的提示先收起。进不了时下面写为什么（`notice`），可以再点。
 * 能进全屏、还没全屏时有「全屏」（同侧边菜单那一格，useBarFullscreen）；旁边是「教程」（`onTutorial`，没有教程时是 null），
 * 点了从头再看一遍。
 */
export function BarDoor({
  notice,
  isEntering,
  onEnter,
  onTutorial,
}: {
  notice: string | null;
  isEntering: boolean;
  onEnter: () => void;
  onTutorial: (() => void) | null;
}) {
  const [frame, setFrame] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setFrame((n) => (Math.random() < 0.15 ? (n + 1) % 3 : 0)), 120);
    return () => window.clearInterval(id);
  }, []);
  const fullscreen = useBarFullscreen();
  const isFullscreenOffered = fullscreen.canFullscreen && !fullscreen.isFullscreen;
  const fullscreenCell = { x: ROW.right - ROW.width, y: ROW.y, width: ROW.width, height: ROW.height };
  const tutorialCell = { ...fullscreenCell, x: fullscreenCell.x - (isFullscreenOffered ? ROW.width : 0) };
  return (
    <>
      <div className="absolute inset-0" style={{ background: BAR_INK.black }} />
      <Sprite name={`intro_${frame}`} x={0} y={0} width={640} height={360} />
      <div className="absolute" style={{ left: SIGN.x, top: SIGN.y, width: SIGN.width, height: SIGN.height, background: frame === 0 ? BAR_INK.pink : BAR_INK.pinkDim }} />
      <PixelText x={SIGN.x} y={SIGN.y + 4} width={SIGN.width} align="center" runs="VA-283" label="" />
      {!isEntering && (
        <PixelText x={0} y={290} width={640} align="center" runs={notice ?? t.enter} color={notice ? BAR_INK.text : BAR_INK.sub} />
      )}
      <HitArea x={0} y={0} width={640} height={360} label={t.enter} onClick={onEnter} />
      {onTutorial && !isEntering && (
        <>
          <PixelText x={tutorialCell.x + 5} y={tutorialCell.y + 1} runs={t.tutorial} label="" />
          <HitArea {...tutorialCell} label={t.tutorial} onClick={onTutorial} />
        </>
      )}
      {isFullscreenOffered && (
        <>
          <PixelText x={fullscreenCell.x + 5} y={fullscreenCell.y + 1} runs={copy.bar.screen.full} label="" />
          <HitArea {...fullscreenCell} label={copy.bar.screen.full} onClick={fullscreen.toggle} />
        </>
      )}
    </>
  );
}
