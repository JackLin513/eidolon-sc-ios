"use client";

import { BarButton } from "@/components/play/bar/BarButton";
import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";
import { copy } from "@/i18n";

const t = copy.bar.end;

/** The card in the middle of the screen (the prototype's `EndPanel`): what it says, one row or two
 * rows apart, and its two buttons under it. */
const CARD = { x: 220, y: 118, width: 200, height: 116 };
const ONE_ROW_Y = 150;
const TWO_ROWS_Y = 140;
const ROW_STEP = 22;
const BUTTONS = { y: 196, again: 236, leave: 332 };

/**
 * 结束卡（.scratch/bar-room spec「一次营业的流程」，照原型的 `EndPanel`）：她告别、最后一页点过以后盖在画面上。
 * 当天第一次写得到了什么（「抽奖 +1」「♥ 好感度上升」，给了什么写什么），什么都没给时只写她走了（没读到她是谁时写「她」）。
 * 「再营业」直接进门迎下一位，「离开」回玩法页。
 */
export function BarEndCard({
  draws,
  affinityUp,
  herName,
  herColor,
  onAgain,
  onLeave,
}: {
  draws: boolean;
  affinityUp: boolean;
  herName: string | null;
  herColor: string;
  onAgain: () => void;
  onLeave: () => void;
}) {
  const rows = [
    ...(draws ? [t.draws] : []),
    ...(affinityUp ? [[{ text: t.heart, color: herColor }, { text: t.affinityUp }]] : []),
  ];
  const top = rows.length > 1 ? TWO_ROWS_Y : ONE_ROW_Y;
  return (
    <div className="absolute inset-0" style={{ background: BAR_INK.veil }}>
      <div
        className="absolute"
        style={{ left: CARD.x, top: CARD.y, width: CARD.width, height: CARD.height, background: BAR_INK.black, border: `1px solid ${BAR_INK.pink}` }}
      />
      {rows.length > 0 ? (
        rows.map((runs, i) => <PixelText key={i} x={CARD.x} y={top + i * ROW_STEP} width={CARD.width} align="center" runs={runs} />)
      ) : (
        <PixelText x={CARD.x} y={ONE_ROW_Y} width={CARD.width} align="center" runs={t.left(herName)} color={BAR_INK.sub} />
      )}
      <BarButton x={BUTTONS.again} y={BUTTONS.y} label={t.again} onClick={onAgain} />
      <BarButton x={BUTTONS.leave} y={BUTTONS.y} label={copy.bar.leave} onClick={onLeave} />
    </div>
  );
}
