"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { HitArea } from "@/components/play/bar/BarScreen";
import { drinkSprite } from "@/components/play/bar/drinkSprites";
import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";
import { Sprite } from "@/components/play/bar/Sprite";
import type { BarSound } from "@/components/play/bar/useBarSound";
import { type Dragged, SHAKER, useShakerDrag } from "@/components/play/bar/useShakerDrag";
import { copy } from "@/i18n";
import type { Drink } from "@/lib/api";
import {
  type BarMixerAction,
  type BarMixerState,
  barMixer,
  canServe,
  FAST_AFTER_MS,
  garble,
  type Ingredient,
  INGREDIENTS,
  isFinished,
  isTakingIngredients,
  shakeStage,
  slotText,
  totalParts,
} from "@/lib/barMixer";

/** Each ingredient: its name on the counter (the original's, untranslated) and where it starts (the
 * longer Bronson Ext a little left of its bottle), its letter in the pictures' names, its key, and
 * where its bottle and its cells are (the original's `amounts_Draw_0`). */
const BOTTLES: Record<Ingredient, { name: string; nameX: number; letter: string; code: string; x: number; y: number }> = {
  adelhyde: { name: "Adelhyde", nameX: 405, letter: "a", code: "KeyQ", x: 405, y: 140 },
  bronson_extract: { name: "Bronson Ext", nameX: 477, letter: "b", code: "KeyW", x: 480, y: 140 },
  powdered_delta: { name: "Pwd Delta", nameX: 555, letter: "d", code: "KeyE", x: 555, y: 140 },
  flanergide: { name: "Flanergide", nameX: 405, letter: "f", code: "KeyR", x: 405, y: 200 },
  karmotrine: { name: "Karmotrine", nameX: 555, letter: "k", code: "KeyT", x: 555, y: 200 },
};
/** The cells of an ingredient start this far right of its bottle; ten of them, five a row. */
const CELLS_DX = 23;
const ICE = { x: 362, y: 123, width: 33, height: 57 };
const AGED = { x: 362, y: 183, width: 33, height: 57 };
const RESET = { x: 402, y: 243, width: 71, height: 25 };
const MIX = { x: 553, y: 243, width: 71, height: 25 };
/** A drink made, in the shaker's place: 35×53, its middle on the shaker's. */
const GLASS = { x: 496, y: 190, width: 35, height: 53 };

/**
 * 调酒台的手感（.scratch/bar-room spec「调酒台」）：lib/barMixer 的动作，加上音效、光圈、飘字、键盘和拖。
 * 调酒台开着（`isCounterOpen`：点单后、上酒的请求不在路上）时才响应；做不了的动作响 `buttonnoclick`（键盘加减不出声）。
 * - 拖（useShakerDrag，`drag`）：材料瓶拖进摇酒器 +1 份，响 `addingredient`、放一圈这种材料颜色的光；
 *   配方书的瓶装（票 09）用同一个 `drag` 拖进来，只在摇酒器空着时进得去。
 * - 键盘：Q W E R T 加一份、按住 Shift 减一份（原版不出声、不放光），A 冰、S 陈化，空格依次是调制、停止、上酒。
 *   通话层展开（页面 inert）时不响应。
 * - 按钮：冰、陈化打开响 `iceadd`、`ageadd`，关掉响 `buttonnoclick`；调制、停止响 `mixdone`，停下飘「成功」或「失败」；
 *   重做杯里有东西响 `buttonclick`；上酒交给 `serve`（服务器收下时 useBarVisit 响 `glassserve`）。
 */
export function useBarCounter({
  mixer,
  isCounterOpen,
  drinks,
  sound,
  onMix,
  serve,
}: {
  mixer: BarMixerState;
  isCounterOpen: boolean;
  drinks: Drink[];
  sound: Pick<BarSound, "play">;
  onMix: (action: BarMixerAction) => void;
  serve: () => void;
}) {
  const [pulse, setPulse] = useState<{ letter: string; id: number } | null>(null);
  const [float, setFloat] = useState<{ isMade: boolean; id: number } | null>(null);
  const [now, setNow] = useState(0);
  const seq = useRef(0);
  const { play } = sound;

  /** Does `action`, with the sound `onDone` if it does anything, `onRefused` if not (null: none). */
  const act = useCallback(
    (action: BarMixerAction, onDone: string | null, onRefused: string | null = "buttonnoclick") => {
      const next = barMixer(mixer, action);
      if (!isCounterOpen || next === mixer) {
        if (onRefused) play(onRefused);
        return null;
      }
      if (onDone) play(onDone);
      onMix(action);
      return next;
    },
    [mixer, isCounterOpen, play, onMix],
  );

  const drop = useCallback(
    (item: Dragged) => {
      const action: BarMixerAction =
        "ingredient" in item ? { type: "add", ingredient: item.ingredient } : { type: "bottle", drink: item.bottle };
      if (act(action, "addingredient") && "ingredient" in item) {
        setPulse({ letter: BOTTLES[item.ingredient].letter, id: ++seq.current });
      }
    },
    [act],
  );
  const drag = useShakerDrag(drop);

  const toggle = useCallback(
    (which: "ice" | "aged") => {
      const isOn = !mixer[which];
      act({ type: which }, isOn ? (which === "ice" ? "iceadd" : "ageadd") : "buttonnoclick");
    },
    [mixer, act],
  );

  /** 调制、停止、上酒，同一个按钮（点摇酒器里调好的也是上酒）。 */
  const mixButton = useCallback(() => {
    const at = performance.now();
    const stage = shakeStage(mixer, at);
    if (isFinished(mixer)) {
      serve();
      return;
    }
    if (stage === "still") {
      act({ type: "shake", now: at }, "mixdone");
      return;
    }
    const next = act({ type: "stop", now: at, drinks, garble: garble() }, "mixdone");
    if (next) setFloat({ isMade: next.made !== null, id: ++seq.current });
  }, [mixer, act, serve, drinks]);

  const reset = useCallback(() => void act({ type: "reset" }, "buttonclick"), [act]);

  // 摇满 5 秒转快摇：到时候重画一次。
  useEffect(() => {
    if (mixer.shake !== "shaking" || mixer.shakenAt === null) return;
    setNow(performance.now());
    const id = window.setTimeout(() => setNow(performance.now()), Math.max(0, mixer.shakenAt + FAST_AFTER_MS - performance.now()));
    return () => window.clearTimeout(id);
  }, [mixer.shake, mixer.shakenAt]);

  // 键盘。按住不放的连发不算；通话层展开（页面 inert）时不响应。
  const keys = useRef({ act, toggle, mixButton, isCounterOpen });
  useEffect(() => {
    keys.current = { act, toggle, mixButton, isCounterOpen };
  });
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const { act, toggle, mixButton, isCounterOpen } = keys.current;
      if (!isCounterOpen || e.repeat || e.ctrlKey || e.metaKey || e.altKey) return;
      if (document.querySelector(".bar-layer")?.closest("[inert]")) return;
      const ingredient = INGREDIENTS.find((i) => BOTTLES[i].code === e.code);
      if (ingredient) act({ type: e.shiftKey ? "remove" : "add", ingredient }, null, null);
      else if (e.code === "KeyA") toggle("ice");
      else if (e.code === "KeyS") toggle("aged");
      else if (e.code === "Space") mixButton();
      else return;
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return { now, drag, pulse, float, toggle, mixButton, reset };
}

export type BarCounterHandle = ReturnType<typeof useBarCounter>;

/**
 * 调酒台（.scratch/bar-room spec「调酒台」，坐标照原型 `pieces.tsx` 的 MixStation 和调研笔记第 2 节）：画在外框上面。
 * 调酒台没开时材料瓶是 `_off`、按钮是 `slot_out`，不写字；拖进瓶装以后材料也变灰。份数格加了的亮、没加的 30% 透明，
 * 11–20 份在同一格上叠一条；摇酒器下面的槽没摇时一格格点亮总份数，停下后写短名，调坏了写乱码。
 * 一单一杯，原版的栏位 1/2 不画。按钮的大小照原版，手机上不另外放大。
 */
export function BarCounter({
  mixer,
  isCounterOpen,
  counter,
}: {
  mixer: BarMixerState;
  isCounterOpen: boolean;
  counter: BarCounterHandle;
}) {
  const { drag } = counter;
  const isLive = isCounterOpen && isTakingIngredients(mixer);
  const stage = shakeStage(mixer, counter.now);
  const total = totalParts(mixer);
  const slot = slotText(mixer);
  const isMade = isFinished(mixer);
  const mixLabel = isMade ? copy.bar.counter.serve : stage === "still" ? copy.bar.counter.mix : copy.bar.counter.stop;
  const isMixDead = isMade ? !canServe(mixer) : stage === "still" && (total === 0 || !isLive);
  const t = copy.bar.counter;

  return (
    <>
      {/* 冰、陈化 */}
      {(
        [
          ["ice", ICE, t.ice],
          ["aged", AGED, t.aged],
        ] as const
      ).map(([which, at, label]) => (
        <div key={which}>
          <PixelText x={at.x} y={at.y + 1} width={at.width} align="center" runs={label} label="" />
          <Sprite name={which === "ice" ? "ice" : "age"} {...at} style={{ opacity: mixer[which] ? 1 : 0.3 }} />
          <HitArea {...at} label={`${label}${mixer[which] ? t.on : t.off}`} onClick={() => counter.toggle(which)} />
        </div>
      ))}
      {/* 材料 */}
      {INGREDIENTS.map((ingredient) => {
        const { name, nameX, letter, x, y } = BOTTLES[ingredient];
        const n = mixer.parts[ingredient];
        const item = { ingredient };
        const isDragged = drag.isDragging(item);
        return (
          <div key={ingredient}>
            <PixelText x={nameX} y={y - 16} runs={name} mono label="" />
            {!isDragged && <Sprite name={isLive ? `ing_${letter}` : `ing_${letter}_off`} x={x} y={y} width={20} height={38} />}
            {Array.from({ length: 10 }, (_, j) => (
              <Sprite
                key={j}
                name={`cell_${letter}`}
                x={x + CELLS_DX + (j % 5) * 9}
                y={y + Math.floor(j / 5) * 18}
                width={8}
                height={17}
                style={{ opacity: j < Math.min(n, 10) ? 1 : 0.3 }}
              />
            ))}
            {Array.from({ length: Math.max(0, n - 10) }, (_, j) => (
              <Sprite
                key={`big${j}`}
                name={`big_${letter}`}
                x={x + CELLS_DX + (j % 5) * 9}
                y={y + Math.floor(j / 5) * 18}
                width={8}
                height={17}
              />
            ))}
            <div
              role="img"
              aria-label={t.parts(name, n)}
              className="absolute"
              style={{
                left: x - 5,
                top: y - 17,
                width: 75,
                height: 57,
                touchAction: "none",
                cursor: !isLive ? undefined : isDragged ? "var(--cur-closed)" : "var(--cur-open)",
              }}
              {...(isLive ? drag.handlers(item) : {})}
            />
          </div>
        );
      })}
      {/* 摇酒器下面的总份数槽：没摇时前 10 份逐格点亮、11–20 份叠一条；停下后写短名或乱码。 */}
      <Sprite name="gauge" x={478} y={250} width={70} height={17} />
      {stage === "still" &&
        !mixer.bottle &&
        Array.from({ length: total }, (_, i) => (
          <Sprite
            key={i}
            name={i < 10 ? "gauge_on" : "gauge_big"}
            x={486 + (i % 5) * 11}
            y={253 + (Math.floor(i / 5) % 2) * 6}
            width={10}
            height={5}
          />
        ))}
      {slot !== null && <PixelText x={482} y={251} runs={slot} mono />}
      {/* 摇酒器，或者调好的饮品、拖进来的瓶装、故障瓶 */}
      {isMade ? (
        <Sprite name={mixer.made ? drinkSprite(mixer.made.drink.id) : "drink_glitch"} {...GLASS} />
      ) : (
        <Sprite
          name={stage !== "still" ? "shaker_shake" : drag.isOverShaker ? "shaker_hover" : "shaker"}
          {...SHAKER}
          className={stage === "slow" ? "bar-shake-slow" : stage === "fast" ? "bar-shake-fast" : undefined}
        />
      )}
      {counter.pulse && <Sprite key={counter.pulse.id} name={`pulse_${counter.pulse.letter}`} {...SHAKER} className="bar-pulse" />}
      {counter.float &&
        (counter.float.isMade ? (
          <Sprite key={counter.float.id} name="success" x={484} y={166} width={59} height={12} className="bar-float" />
        ) : (
          <Sprite key={counter.float.id} name="fail" x={492} y={164} width={102} height={15} className="bar-float" />
        ))}
      {isMade && <HitArea {...SHAKER} label={t.serve} onClick={counter.mixButton} />}
      {/* 重做、调制 / 停止 / 上酒 */}
      {/* 重做按下时换 `reset_hover`、往下沉 1px（bar.css 的 `.bar-press`）。 */}
      <div className="bar-press">
        <Sprite name={isCounterOpen ? "reset" : "slot_out"} {...RESET} className="bar-press-up" />
        {isCounterOpen && (
          <>
            <Sprite name="reset_hover" {...RESET} className="bar-press-down" />
            <PixelText x={RESET.x} y={RESET.y + 4} width={RESET.width} align="center" runs={t.reset} color={BAR_INK.button} label="" />
          </>
        )}
        <HitArea {...RESET} label={t.reset} onClick={counter.reset} />
      </div>
      <Sprite name={!isCounterOpen ? "slot_out" : isMixDead ? "mix_no" : "mix_yes"} {...MIX} />
      {isCounterOpen && (
        <PixelText x={MIX.x} y={MIX.y + 4} width={MIX.width} align="center" runs={mixLabel} color={BAR_INK.button} label="" />
      )}
      <HitArea {...MIX} label={mixLabel} onClick={counter.mixButton} />
      {/* 跟着指针走的瓶子：材料是拖动中的 `_hover`，瓶装是它自己的图。 */}
      {drag.drag &&
        ("ingredient" in drag.drag.item ? (
          <Sprite
            name={`ing_${BOTTLES[drag.drag.item.ingredient].letter}_hover`}
            x={Math.round(drag.drag.x - 10)}
            y={Math.round(drag.drag.y - 19)}
            width={20}
            height={38}
          />
        ) : (
          <Sprite
            name={drinkSprite(drag.drag.item.bottle.id)}
            x={Math.round(drag.drag.x - 17)}
            y={Math.round(drag.drag.y - 26)}
            width={35}
            height={53}
          />
        ))}
    </>
  );
}
