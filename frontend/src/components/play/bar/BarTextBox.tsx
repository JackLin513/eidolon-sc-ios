"use client";

import { useEffect, useState } from "react";

import { HitArea } from "@/components/play/bar/BarScreen";
import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText, type PixelRun } from "@/components/play/bar/PixelText";
import { Sprite } from "@/components/play/bar/Sprite";
import { copy } from "@/i18n";
import type { TextRow } from "@/lib/barText";
import type { VisitLine } from "@/lib/barVisit";

/** The original's text box, under the guest's window, and where the text starts in it. */
const BOX = { x: 17, y: 276, width: 412, height: 65 };
const INSET = { x: 6, y: 3 };
/** `arrow_text_2`: four frames, one every 111 ms (the original's image_speed 0.3). */
const ARROW_FRAMES = 4;
const ARROW_FRAME_MS = 111;

/** The glove's NEXT bubble over the text box: four frames, as quick as the arrow. */
const NEXT_FRAMES = 4;

/**
 * 文本框（.scratch/bar-room spec「文本框和打字」）：一页台词，名字按角色上色、接冒号（她用官方色，制作人用原型的「我」色），
 * 正文白色，她的中文字幕灰色。打完右下角 `arrow_text_2` 上下跳。点哪都算：交给 lib/barVisit，先打完、再翻页。
 * 电脑上鼠标停在文本框上是会动的 NEXT 气泡（`isNextCursor`：点了有用的时候）。
 */
export function BarTextBox({
  text,
  herColor,
  isArrowShown,
  isNextCursor,
  onTap,
}: {
  text: { line: VisitLine; rows: TextRow[] } | null;
  herColor: string;
  isArrowShown: boolean;
  isNextCursor: boolean;
  onTap: () => void;
}) {
  const [frame, setFrame] = useState(0);
  const isMoving = isArrowShown || isNextCursor;
  useEffect(() => {
    if (!isMoving) return;
    const id = window.setInterval(() => setFrame((n) => n + 1), ARROW_FRAME_MS);
    return () => window.clearInterval(id);
  }, [isMoving]);

  const runs: PixelRun[] = [];
  text?.rows.forEach((row, i) => {
    if (i > 0) runs.push({ text: "\n" });
    if (row.name) runs.push({ text: row.name, color: text.line.speaker === "her" ? herColor : BAR_INK.producer });
    runs.push({ text: row.text, color: row.subtitle ? BAR_INK.sub : BAR_INK.text });
  });
  return (
    <>
      {text && <PixelText x={BOX.x + INSET.x} y={BOX.y + INSET.y} runs={runs} />}
      {isArrowShown && <Sprite name={`arrow_${frame % ARROW_FRAMES}`} x={BOX.x + BOX.width - 16} y={BOX.y + BOX.height - 13} width={8} height={8} />}
      <HitArea
        {...BOX}
        label={copy.bar.next}
        cursor={isNextCursor ? `var(--cur-next-${frame % NEXT_FRAMES})` : undefined}
        onClick={onTap}
      />
    </>
  );
}
