"use client";

import { useCallback, useEffect, useReducer, useRef, useState } from "react";

import { loadPixelFont, measurePixelText } from "@/components/play/bar/PixelText";
import type { BarSound } from "@/components/play/bar/useBarSound";
import { useTypingClock } from "@/components/play/bar/useTypingClock";
import { copy } from "@/i18n";
import type { Character } from "@/lib/api";
import { type BarMixerAction, canServe } from "@/lib/barMixer";
import { paginate } from "@/lib/barText";
import {
  type BarTutorialAction,
  type BarTutorialState,
  barTutorial,
  beginTutorial,
  hasSeenTutorial,
  keepTutorialSeen,
  type TutorialEnd,
} from "@/lib/barTutorial";

/** Who teaches: はづき. */
const TEACHER = "hazuki";
/** What plays through it, looped: Every Day is Night. */
const TUTORIAL_TRACK = 22;

type Action = BarTutorialAction | { type: "begin"; state: BarTutorialState } | { type: "over" };

function reducer(state: BarTutorialState | null, action: Action): BarTutorialState | null {
  if (action.type === "begin") return action.state;
  if (action.type === "over") return null;
  return state && barTutorial(state, action);
}

/**
 * 教程（.scratch/bar-room spec「教程」）：lib/barTutorial 的状态，加上计时、声音和「看过」。不调接口。
 *
 * - `isSeen`：这台设备上这位用户看过没有（读出来、角色读到之前是 null）；没看过时第一次进门就是教程。
 *   没有 はづき 时没有教程（`canBegin` 为假），当作看过。
 * - `begin()` 要在点击里调（店门口进门、「教程」按钮）：响门声、建 AudioContext，循环放 Every Day is Night（取不到就静音），
 *   はづき 进来照台词往下走。等像素字载入的这一会儿再点不会再开始一次。
 * - `tap`、`mix`、`serve`、`skip` 交给 lib/barTutorial；上不了的酒响 `buttonnoclick`，上了响 `glassserve`。
 * - 走完或跳过：记下看过，停掉那首，调 `onEnd`（去选曲界面、或回店门口），教程收起。中途离开、刷新不记。
 */
export function useBarTutorial({
  userId,
  characters,
  hasJukebox,
  sound,
  music,
  onEnd,
}: {
  userId: string | null;
  characters: Character[] | null;
  hasJukebox: boolean;
  sound: Pick<BarSound, "start" | "play">;
  music: { loopTrack: (id: number) => void; stopPreview: () => void };
  onEnd: (end: TutorialEnd) => void;
}) {
  const [state, dispatch] = useReducer(reducer, null);
  const [seen, setSeen] = useState<{ userId: string; isSeen: boolean } | null>(null);
  const teacher = characters?.find((c) => c.id === TEACHER) ?? null;

  useEffect(() => {
    if (userId) setSeen({ userId, isSeen: hasSeenTutorial(userId) });
  }, [userId]);

  const isBeginning = useRef(false);
  const begin = useCallback(async () => {
    if (!teacher || isBeginning.current) return;
    isBeginning.current = true;
    sound.start();
    sound.play("door");
    music.loopTrack(TUTORIAL_TRACK);
    // 量字要用像素字：没载入就量，退回的字体宽度不一样，分页会错。
    await loadPixelFont().catch(() => {});
    const names = { her: teacher.short_name ?? teacher.name, producer: copy.bar.producer };
    const layout = (line: Parameters<typeof paginate>[0]) => paginate(line, { names, measure: measurePixelText });
    dispatch({
      type: "begin",
      state: beginTutorial({ characterId: teacher.id, hasJukebox, layout, now: performance.now() }),
    });
    isBeginning.current = false;
  }, [teacher, hasJukebox, sound, music]);

  // 走完或跳过：记下看过，停掉那首，接着去哪。
  const end = state?.end ?? null;
  useEffect(() => {
    if (!state || end === null) return;
    if (userId) {
      keepTutorialSeen(userId, state);
      setSeen({ userId, isSeen: true });
    }
    music.stopPreview();
    dispatch({ type: "over" });
    onEnd(end);
  }, [state, end, userId, music, onEnd]);

  const now = useTypingClock(state?.visit.shown ?? null);

  const tap = useCallback(() => dispatch({ type: "tap", now: performance.now() }), []);
  const mix = useCallback((action: BarMixerAction) => dispatch({ type: "mix", action }), []);
  const skip = useCallback(() => dispatch({ type: "skip" }), []);
  const serve = useCallback(() => {
    const visit = state?.visit;
    if (!visit?.isMixing || !canServe(visit.mixer)) {
      sound.play("buttonnoclick");
      return;
    }
    sound.play("glassserve");
    dispatch({ type: "serve", now: performance.now() });
  }, [state, sound]);

  const isSeen = seen && seen.userId === userId ? seen.isSeen : null;
  return {
    state,
    now,
    /** Seen on this device (null till read, and till the characters are); with no はづき there is none to see. */
    isSeen: characters === null ? null : teacher ? isSeen : true,
    canBegin: teacher !== null,
    begin,
    tap,
    mix,
    serve,
    skip,
  };
}
