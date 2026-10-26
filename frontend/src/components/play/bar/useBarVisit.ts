"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useReducer, useRef, useState } from "react";

import { loadPixelFont, measurePixelText } from "@/components/play/bar/PixelText";
import type { BarSound } from "@/components/play/bar/useBarSound";
import { copy } from "@/i18n";
import { ApiError, type Character, enterBar, leaveBarVisit, retryBarVisit, serveBarDrink } from "@/lib/api";
import { type BarMixerAction, garble, served } from "@/lib/barMixer";
import { CHARS_PER_SECOND, paginate, typedOutAt } from "@/lib/barText";
import { atTheDoor, barVisit, doorNotice, endCard, type VisitEvent } from "@/lib/barVisit";
import { playHref } from "@/lib/playRoute";

/** How often the box redraws while a page types out: once a character. */
const TYPING_TICK_MS = 1000 / CHARS_PER_SECOND;

/** The events a call ends on: one ended before them was cut off. */
const LAST_EVENTS: ReadonlySet<VisitEvent["type"]> = new Set(["waiting", "failed", "done"]);

/**
 * 一次光顾（.scratch/bar-room spec「一次营业的流程」「接光顾的接口」）：lib/barVisit 的状态，加上计时和接口。
 * 点店门口调 `POST /api/bar/visits`（带自带的 LLM，照文字回合），把它推来的事件和玩家的点击交给 lib/barVisit；
 * 一页在打字时每个字重画一次，打完时告诉它一声（点单句打完才开调酒台）。
 * 关着（409）回玩法页；离开、换页时关掉这次调用、`DELETE` 这次光顾；关页面、刷新时也尽量发出 `DELETE`。
 * 文本框里她的名字按 `visit` 推来的 `character_id` 在 `characters` 里找，每句来时找一次；角色读到之前店门口点了不进。
 * 进门那一下响门声、放曲目（useBarSound 要在这一下点击里开始）。
 * 上酒（`serve`）：调 `POST …/serves`，上不了的只响 `buttonnoclick`；收下了响 `glassserve`，接着打它推来的句子，
 * 拒了交给 lib/barVisit（422 故障瓶、410 回店门口、409 照旧）。
 * 出错（`failed`）后「再试一次」（`retry`）调 `POST …/retry`，同样交给 lib/barVisit（409 照旧、410 回店门口）。
 * 结束卡上「再营业」（`again`）不回店门口、不重新放曲目，只响门声，下一位接着进门；这一次得了抽奖（`done` 的
 * `rewarded.draws`）时告诉一声（`onDraws`）。光顾中途调用断了（抛错、或者没等到 `waiting`、`failed`、`done` 就完了）
 * 回店门口：服务器那边这次光顾也随之没了。
 */
export function useBarVisit({
  userId,
  characters,
  sound,
  onDraws,
}: {
  userId: string | null;
  characters: Character[] | null;
  sound: Pick<BarSound, "start" | "play">;
  onDraws: () => void;
}) {
  const router = useRouter();
  const [state, dispatch] = useReducer(barVisit, undefined, atTheDoor);
  const [now, setNow] = useState(() => performance.now());
  const call = useRef<AbortController | null>(null);
  const visitId = useRef<string | null>(null);
  const herId = useRef("");
  const roster = useRef(characters);
  const latest = useRef(state);
  const onDrawsRef = useRef(onDraws);
  useEffect(() => {
    roster.current = characters;
    latest.current = state;
    onDrawsRef.current = onDraws;
  });

  /** A call's events handed to lib/barVisit as they come, each line laid out in pages; throws if
   * the call ends cut off. */
  const follow = useCallback(async (events: AsyncIterable<VisitEvent>) => {
    let isEnded = false;
    for await (const event of events) {
      isEnded = LAST_EVENTS.has(event.type);
      if (event.type === "line") {
        const { type: _, ...line } = event;
        const her = roster.current?.find((c) => c.id === herId.current);
        const names = { her: her ? (her.short_name ?? her.name) : "", producer: copy.bar.producer };
        const pages = paginate(line, { names, measure: measurePixelText });
        dispatch({ type: "line", line, pages, now: performance.now() });
      } else {
        if (event.type === "visit") {
          visitId.current = event.visit_id;
          herId.current = event.character_id;
        }
        if (event.type === "done") {
          visitId.current = null; // 光顾已经结束，离开时不用再 DELETE。
          if ((event.rewarded?.draws ?? 0) > 0) onDrawsRef.current();
        }
        dispatch({ type: "event", event });
      }
    }
    if (!isEnded) throw new Error("the visit's call was cut off");
  }, []);

  /** The visit's call cut off part-way: back at the door, the visit gone with it. */
  const cutOff = useCallback(() => {
    call.current = null;
    visitId.current = null;
    dispatch({ type: "gone" });
  }, []);

  /** The visit's call closed and the visit left, if one is under way. */
  const close = useCallback((leaving: { keepalive: boolean }) => {
    call.current?.abort();
    call.current = null;
    const id = visitId.current;
    visitId.current = null;
    if (id) void leaveBarVisit(id, leaving).catch(() => {});
  }, []);

  /** `POST /api/bar/visits` and its call followed: from the door, or for the next guest. */
  const startVisit = useCallback(
    async (userId: string) => {
      call.current?.abort(); // 上一位告别的那次调用还开着的话，关掉，免得它晚到的错误把这一位送回店门口。
      const controller = new AbortController();
      call.current = controller;
      visitId.current = null;
      herId.current = "";
      try {
        // 量字要用像素字：没载入就量，退回的字体宽度不一样，分页会错。
        await loadPixelFont().catch(() => {});
        await follow(enterBar(userId, controller.signal));
      } catch (e) {
        if (controller.signal.aborted || call.current !== controller) return;
        if (visitId.current) return cutOff();
        if (e instanceof ApiError && e.status === 409) {
          router.push(playHref());
          return;
        }
        dispatch({ type: "refused", notice: doorNotice(e instanceof ApiError ? e : null) });
      }
    },
    [router, follow, cutOff],
  );

  const enter = useCallback(async () => {
    if (!userId || !characters || state.stage !== "door") return;
    sound.start();
    sound.play("door");
    dispatch({ type: "enter" });
    await startVisit(userId);
  }, [userId, characters, state.stage, sound, startVisit]);

  /** 「再营业」：曲目接着放，下一位进门。 */
  const again = useCallback(async () => {
    if (!userId || !endCard(latest.current)) return;
    sound.play("door");
    dispatch({ type: "again" });
    latest.current = { ...latest.current, done: null };
    await startVisit(userId);
  }, [userId, sound, startVisit]);

  const mix = useCallback((action: BarMixerAction) => dispatch({ type: "mix", action }), []);

  const serve = useCallback(async () => {
    const { isMixing, isServing, mixer } = latest.current;
    const id = visitId.current;
    const body = served(mixer);
    if (!id || !body || !isMixing || isServing) {
      sound.play("buttonnoclick");
      return;
    }
    dispatch({ type: "serve" });
    latest.current = { ...latest.current, isServing: true };
    const controller = new AbortController();
    call.current = controller;
    let isTaken = false;
    try {
      const events = await serveBarDrink(id, body, controller.signal);
      isTaken = true;
      sound.play("glassserve");
      dispatch({ type: "served" });
      await follow(events);
    } catch (e) {
      if (controller.signal.aborted || call.current !== controller) return;
      if (isTaken) return cutOff();
      const status = e instanceof ApiError ? e.status : null;
      if (status === 410) visitId.current = null;
      dispatch({ type: "serveRefused", status, garble: garble() });
    }
  }, [sound, follow, cutOff]);

  /** 「再试一次」：出错的那次调用再来一遍。 */
  const retry = useCallback(async () => {
    const { failure, isRetrying } = latest.current;
    const id = visitId.current;
    if (!id || failure === null || isRetrying) return;
    dispatch({ type: "retry" });
    latest.current = { ...latest.current, isRetrying: true };
    const controller = new AbortController();
    call.current = controller;
    let isTaken = false;
    try {
      const events = await retryBarVisit(id, controller.signal);
      isTaken = true;
      dispatch({ type: "retried" });
      await follow(events);
    } catch (e) {
      if (controller.signal.aborted || call.current !== controller) return;
      if (isTaken) return cutOff();
      const status = e instanceof ApiError ? e.status : null;
      if (status === 410) visitId.current = null;
      dispatch({ type: "retryRefused", status });
    }
  }, [follow, cutOff]);

  const tap = useCallback(() => dispatch({ type: "tap", now: performance.now() }), []);

  /** The visit under way left, its call closed: back at the door. */
  const leave = useCallback(() => {
    close({ keepalive: false });
    dispatch({ type: "left" });
  }, [close]);

  // 换到别的页（离开、浏览器返回）时离开；关页面、刷新时也发一个（keepalive 的）DELETE。
  useEffect(() => {
    const onPageHide = () => close({ keepalive: true });
    window.addEventListener("pagehide", onPageHide);
    return () => {
      window.removeEventListener("pagehide", onPageHide);
      close({ keepalive: false });
    };
  }, [close]);

  // 一页在打字时每个字重画一次；打完时告诉 lib/barVisit。
  const { shown } = state;
  useEffect(() => {
    if (!shown) return;
    const end = typedOutAt(shown.page, shown.typing);
    if (shown.typing.finished || performance.now() >= end) {
      setNow(performance.now());
      dispatch({ type: "tick", now: performance.now() });
      return;
    }
    const id = window.setInterval(() => {
      const at = performance.now();
      setNow(at);
      if (at >= end) {
        window.clearInterval(id);
        dispatch({ type: "tick", now: at });
      }
    }, TYPING_TICK_MS);
    return () => window.clearInterval(id);
  }, [shown]);

  return { state, now, enter, again, tap, leave, mix, serve, retry };
}
