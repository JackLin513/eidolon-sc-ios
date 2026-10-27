"use client";

import { HitArea } from "@/components/play/bar/BarScreen";
import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";

/** The size of a framed button: the prototype's `EndPanel` buttons. */
export const BAR_BUTTON = { width: 72, height: 22 };

/** 白框里写一行字的按钮（原型 `EndPanel` 的「再营业」「离开」）：结束卡和文本框的「再试一次」。`x`、`y` 是左上角。 */
export function BarButton({ x, y, label, onClick }: { x: number; y: number; label: string; onClick: () => void }) {
  return (
    <>
      <div className="absolute" style={{ left: x, top: y, ...BAR_BUTTON, border: `1px solid ${BAR_INK.text}` }} />
      <PixelText x={x} y={y + 3} width={BAR_BUTTON.width} align="center" runs={label} label="" />
      <HitArea x={x} y={y} {...BAR_BUTTON} label={label} onClick={onClick} />
    </>
  );
}
