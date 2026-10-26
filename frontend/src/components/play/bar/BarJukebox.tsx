"use client";

import { type PointerEvent as ReactPointerEvent, useEffect, useRef, useState } from "react";

import { HitArea, usePointer } from "@/components/play/bar/BarScreen";
import { BAR_INK } from "@/components/play/bar/ink";
import { measurePixelText, PixelText } from "@/components/play/bar/PixelText";
import { Sprite } from "@/components/play/bar/Sprite";
import type { BarJukebox } from "@/components/play/bar/useBarJukebox";
import type { BarSound } from "@/components/play/bar/useBarSound";
import { copy } from "@/i18n";
import type { BarTrack } from "@/lib/barAudio";
import {
  clearSlot,
  isReady,
  jukeboxPage,
  jukeboxPages,
  type JukeboxSlots,
  pickTrack,
  swapSlots,
} from "@/lib/barJukebox";
import { wrapText } from "@/lib/barText";

const t = copy.bar.jukebox;

/** How long the wipe in takes: the controls come after it, with 「boot_up」. */
const BOOT_MS = 1130;
/** How long the pointer stays on a name before it plays (the original's). */
const PREVIEW_MS = 2500;
/** How long a finger stays down before it is a long press, not a tap. */
const LONG_PRESS_MS = 550;
/** A slot, a name, the title box: the original's 191×25. */
const ROW = { width: 191, height: 25 };
/** Where the slots are: two columns of six, 30 px apart. */
const slotAt = (i: number) => ({ x: i < 6 ? 225 : 425, y: 40 + (i % 6) * 30 });
const READY = { x: 358, y: 220, width: 58, height: 32 };
/** The help in the text box at the bottom left. */
const HELP = { x: 26, width: 374 };

/**
 * 选曲界面（.scratch/bar-room spec「点唱机」，照原型 `jukebox.tsx` 的 JukeboxSetup）：整张 640×360 盖在上面，底图从上往下
 * 擦出，擦出时「JUKEBOX 3」横向长出来，擦完才有控件。12 个槽一进来就照上次的（`slots`）填好。
 * 左边 5 首一页，点曲名放进第一个空槽（可以重复）；右边点一个槽选中（变黄），再点另一个对调；电脑右键、手机长按清掉一个，
 * 后面不补位。12 个槽满了 Ready! 才是绿的，点了只交出选择（`onReady`），不放。
 * 试听（`jukebox.preview`）：电脑鼠标停在曲名上 2.5 秒放，移开就停；手机长按曲名，同样等 2.5 秒放（长按认出来以后才出等待动画），
 * 松手接着放，点任何地方或长按另一首就停。
 */
export function BarJukeboxSetup({
  tracks,
  slots: initial,
  jukebox,
  sound,
  onReady,
}: {
  tracks: BarTrack[];
  slots: JukeboxSlots;
  jukebox: Pick<BarJukebox, "previewing" | "preview" | "stopPreview">;
  sound: Pick<BarSound, "play">;
  onReady: (slots: JukeboxSlots) => void;
}) {
  const { play } = sound;
  const { previewing, preview, stopPreview } = jukebox;
  const [isBooted, setBooted] = useState(false);
  const [slots, setSlots] = useState(initial);
  const [page, setPage] = useState(0);
  const [picked, setPicked] = useState<number | null>(null);
  const [halo, setHalo] = useState<{ slot: number; n: number } | null>(null);
  /** The name waited on to preview, its wait shown. */
  const [waiting, setWaiting] = useState<number | null>(null);
  const [frame, setFrame] = useState(0);
  const isCoarse = usePointer() === "coarse";
  const timers = useRef<number[]>([]);
  /** A long press just ended: the click that follows it is not a tap. */
  const isLongPress = useRef(false);
  const pages = jukeboxPages(tracks);
  const titleOf = (id: number | null) => tracks.find((track) => track.id === id)?.title ?? null;

  useEffect(() => {
    const id = window.setTimeout(() => {
      setBooted(true);
      play("boot_up");
    }, BOOT_MS);
    return () => window.clearTimeout(id);
  }, [play]);
  useEffect(() => {
    if (waiting === null) return;
    const id = window.setInterval(() => setFrame((n) => (n + 1) % 4), 133);
    return () => window.clearInterval(id);
  }, [waiting]);
  useEffect(() => () => timers.current.forEach((id) => window.clearTimeout(id)), []);

  const clearTimers = () => {
    timers.current.forEach((id) => window.clearTimeout(id));
    timers.current = [];
  };
  const after = (ms: number, then: () => void) => timers.current.push(window.setTimeout(then, ms));
  /** Waits on `id`, then previews it. */
  const waitToPreview = (id: number, waited: number) =>
    after(PREVIEW_MS - waited, () => {
      setWaiting(null);
      preview(id);
    });

  const add = (id: number) => {
    if (isReady(slots)) return play("buttonnoclick");
    play("jukeselect");
    setSlots(pickTrack(slots, id));
    const slot = slots.indexOf(null);
    setHalo((h) => ({ slot, n: (h?.n ?? 0) + 1 }));
  };
  const tapSlot = (i: number) => {
    if (slots[i] === null) return;
    if (picked === null) {
      play("jukepick");
      setPicked(i);
      return;
    }
    play("jukechange");
    setSlots(swapSlots(slots, picked, i));
    setPicked(null);
  };
  const remove = (i: number) => {
    if (slots[i] === null) return;
    play("prompt");
    setSlots(clearSlot(slots, i));
    if (picked === i) setPicked(null);
  };
  const turn = (step: number) => {
    const to = page + step;
    if (to < 0 || to >= pages) return play("jukechange");
    play("jukepick");
    setPage(to);
  };
  const ready = () => {
    if (!isReady(slots)) return play("buttonnoclick");
    play("mixdone");
    onReady(slots);
  };

  /** Pointer handlers for a press: a long press does `onLong` (once it is one) and swallows the click. */
  const touchPress = (onDown: () => void, onLong: () => void) => ({
    onPointerDown: (e: ReactPointerEvent) => {
      if (e.pointerType !== "touch") return;
      isLongPress.current = false;
      clearTimers();
      onDown();
      after(LONG_PRESS_MS, () => {
        isLongPress.current = true;
        onLong();
      });
    },
    onPointerUp: () => clearTimers(),
    onPointerCancel: () => clearTimers(),
  });
  const isTap = () => {
    const wasLong = isLongPress.current;
    isLongPress.current = false;
    return !wasLong;
  };

  const help = wrapText(isCoarse ? t.howTo.coarse : t.howTo.fine, HELP.width, measurePixelText);
  return (
    <div
      className="absolute inset-0"
      // 手机上试听着时，点哪里都停（长按另一首也是先停再等）。
      onPointerDownCapture={(e) => {
        if (e.pointerType === "touch" && previewing !== null) stopPreview();
      }}
      // 手机上长按没到 2.5 秒就松手：不放了。
      onPointerUp={(e) => e.pointerType === "touch" && setWaiting(null)}
      onContextMenu={(e) => e.preventDefault()}
    >
      <div className="bar-juke-wipe absolute inset-0">
        <Sprite name="juke_frame" x={0} y={0} width={640} height={360} />
      </div>
      {!isBooted && <Sprite name="juke_startup" x={189} y={60} width={263} height={147} className="bar-juke-startup" />}
      {isBooted && (
        <>
          <Sprite name="juke_slot_blue" x={25} y={38} {...ROW} />
          <PixelText x={25} y={42} width={ROW.width} align="center" runs={t.title} color={BAR_INK.jukeTitle} mono />
          {jukeboxPage(tracks, page).map((track, n) => {
            const y = 78 + n * 30;
            const isLit = waiting === track.id || previewing === track.id;
            return (
              <div key={track.id}>
                <Sprite name={isLit ? "juke_slot_yellow" : "juke_slot_blue"} x={25} y={y} {...ROW} />
                <PixelText x={25} y={y + 4} width={ROW.width} align="center" runs={track.title} mono label="" />
                <button
                  type="button"
                  aria-label={track.title}
                  className="bar-hit absolute"
                  style={{ left: 25, top: y, ...ROW }}
                  onPointerEnter={(e) => {
                    if (e.pointerType !== "mouse") return;
                    play("mouse_hover");
                    clearTimers();
                    setWaiting(track.id);
                    waitToPreview(track.id, 0);
                  }}
                  onPointerLeave={(e) => {
                    if (e.pointerType !== "mouse") return;
                    clearTimers();
                    setWaiting(null);
                    stopPreview();
                  }}
                  {...touchPress(
                    () => setWaiting(null),
                    () => {
                      setWaiting(track.id);
                      waitToPreview(track.id, LONG_PRESS_MS);
                    },
                  )}
                  onClick={() => isTap() && add(track.id)}
                />
              </div>
            );
          })}
          <button
            type="button"
            aria-label={t.prevPage}
            className="bar-hit absolute"
            style={{ left: 26, top: 232, width: 24, height: 24, opacity: page === 0 ? 0.4 : 1 }}
            onClick={() => turn(-1)}
          >
            <Sprite name="arrow" x={0} y={0} width={24} height={24} style={{ transform: "scaleX(-1)" }} />
          </button>
          <PixelText x={95} y={236} width={60} align="center" runs={`${page + 1}/${pages}`} mono />
          <button
            type="button"
            aria-label={t.nextPage}
            className="bar-hit absolute"
            style={{ left: 193, top: 232, width: 24, height: 24, opacity: page === pages - 1 ? 0.4 : 1 }}
            onClick={() => turn(1)}
          >
            <Sprite name="arrow" x={0} y={0} width={24} height={24} />
          </button>
          {waiting !== null && <Sprite name={`juke_preview_${frame}`} x={235} y={220} width={95} height={40} />}
          {slots.map((id, i) => {
            const { x, y } = slotAt(i);
            const isPicked = picked === i;
            const title = titleOf(id);
            return (
              <div key={i}>
                <Sprite name={isPicked ? "juke_slot_yellow" : "juke_slot_red"} x={x} y={y} {...ROW} />
                <PixelText
                  x={x + 4}
                  y={y + 4}
                  width={14}
                  align="center"
                  runs={String(i + 1)}
                  color={isPicked ? BAR_INK.lit : BAR_INK.jukeSlot}
                  mono
                  label=""
                />
                {title !== null && <PixelText x={x + 16} y={y + 4} width={175} align="center" runs={title} mono label="" />}
                {halo?.slot === i && (
                  <div
                    key={halo.n}
                    className="bar-juke-halo absolute"
                    style={{ left: x, top: y, ...ROW, border: `1px solid ${BAR_INK.text}` }}
                  />
                )}
                <button
                  type="button"
                  aria-label={t.slot(i + 1, title)}
                  aria-pressed={isPicked}
                  className="bar-hit absolute"
                  style={{ left: x, top: y, ...ROW }}
                  onContextMenu={(e) => {
                    e.preventDefault();
                    // 手机的长按也会弹出 contextmenu：长按自己会清。
                    if (!isLongPress.current) remove(i);
                  }}
                  {...touchPress(
                    () => {},
                    () => remove(i),
                  )}
                  onClick={() => isTap() && tapSlot(i)}
                />
              </div>
            );
          })}
          <Sprite name={isReady(slots) ? "juke_ready_green" : "juke_ready_red"} {...READY} />
          <button
            type="button"
            aria-label={t.ready}
            aria-disabled={!isReady(slots)}
            className="bar-hit absolute"
            style={{ left: READY.x, top: READY.y, width: READY.width, height: READY.height }}
            onClick={ready}
          />
          <PixelText x={HELP.x} y={279} runs={t.add} color={BAR_INK.jukeHint} />
          <PixelText x={HELP.x} y={298} runs={help.join("\n")} label={help.join("")} />
        </>
      )}
    </div>
  );
}

/** The small player's buttons: where the original hits them on the screen. */
const PLAYER_BUTTONS = {
  previous: { x: 446, y: 55, width: 30, height: 13 },
  pause: { x: 482, y: 49, width: 17, height: 25 },
  next: { x: 505, y: 55, width: 30, height: 13 },
  shuffle: { x: 545, y: 51, width: 30, height: 21 },
  loop: { x: 582, y: 54, width: 31, height: 15 },
};

/**
 * 店里的小播放器（照原型的 SmallPlayer，原版 small_jukebox_obj）：盖在右上角的 logo 上 (435,27) 188×63，从上往下展开。
 * 底板随放着、暂停换图；上一首、下一首按下时亮黄、淡出；随机、单曲循环开着时一直亮黄（两者互斥）。曲名白字带灰影。
 * 高亮图不画在底板的左上角，画在各按钮对象的位置（随机、单曲循环 (438,29)，上一首、下一首 (439,29)）。
 */
export function BarJukeboxPlayer({ jukebox, sound }: { jukebox: BarJukebox; sound: Pick<BarSound, "play"> }) {
  const [flash, setFlash] = useState<{ which: "back" | "next"; n: number } | null>(null);
  const state = jukebox.jukebox;
  if (!state) return null;
  const p = t.player;
  const button = (label: string, at: (typeof PLAYER_BUTTONS)[keyof typeof PLAYER_BUTTONS], onClick: () => void, pressed?: boolean) => (
    <HitArea
      {...at}
      label={label}
      pressed={pressed}
      onClick={() => {
        sound.play("buttonclick");
        onClick();
      }}
    />
  );
  const flashOn = (which: "back" | "next") => setFlash((f) => ({ which, n: (f?.n ?? 0) + 1 }));
  return (
    <div className="bar-juke-open absolute inset-0" style={{ transformOrigin: "0 27px", pointerEvents: "none" }}>
      <div style={{ pointerEvents: "auto" }}>
        <Sprite name={state.isPaused ? "juke_small_paused" : "juke_small_playing"} x={435} y={27} width={188} height={63} />
        {state.mode === "shuffle" && <Sprite name="juke_shuffle" x={438} y={29} width={188} height={63} />}
        {state.mode === "loop" && <Sprite name="juke_loop" x={438} y={29} width={188} height={63} />}
        {flash && <Sprite key={flash.n} name={`juke_${flash.which}`} x={439} y={29} width={188} height={63} className="bar-juke-flash" />}
        <PixelText x={442} y={70} runs={jukebox.title} color={BAR_INK.off} mono label="" />
        <PixelText x={442} y={69} runs={jukebox.title} mono />
        {button(p.previous, PLAYER_BUTTONS.previous, () => {
          flashOn("back");
          jukebox.previous();
        })}
        {button(state.isPaused ? p.play : p.pause, PLAYER_BUTTONS.pause, jukebox.togglePause)}
        {button(p.next, PLAYER_BUTTONS.next, () => {
          flashOn("next");
          jukebox.next();
        })}
        {button(p.shuffle, PLAYER_BUTTONS.shuffle, () => jukebox.changeMode("shuffle"), state.mode === "shuffle")}
        {button(p.loop, PLAYER_BUTTONS.loop, () => jukebox.changeMode("loop"), state.mode === "loop")}
      </div>
    </div>
  );
}
