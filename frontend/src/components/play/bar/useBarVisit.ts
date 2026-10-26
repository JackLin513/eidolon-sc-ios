"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useReducer, useRef, useState } from "react";

import { loadPixelFont, measurePixelText } from "@/components/play/bar/PixelText";
import { copy } from "@/i18n";
import { ApiError, enterBar, leaveBarVisit } from "@/lib/api";
import { paginate, typedOutAt } from "@/lib/barText";
import { atTheDoor, barVisit, doorNotice } from "@/lib/barVisit";
import { playHref } from "@/lib/playRoute";

/** How often the box redraws while a page types out: once a character. */
const TYPING_TICK_MS = 1000 / 30;

/**
 * 一次光顾（.scratch/bar-room spec「一次营业的流程」「接光顾的接口」）：lib/barVisit 的状态，加上计时和接口。
 * 点店门口调 `POST /api/bar/visits`（带自带的 LLM，照文字回合），把它推来的事件和玩家的点击交给 lib/barVisit；
 * 一页在打字时每个字重画一次，打完时告诉它一声（点单句打完才开调酒台）。
 * 关着（409）回玩法页；离开、换页时关掉这次调用、`DELETE` 这次光顾；关页面、刷新时也尽量发出 `DELETE`。
 * `herName` 是文本框里她的名字，进门时她是谁还不知道，所以按 `visit` 推来的 `character_id` 问。
 */
export function useBarVisit({ userId, herName }: { userId: string | null; herName: (characterId: string) => string }) {
  const router = useRouter();
  const [state, dispatch] = useReducer(barVisit, undefined, atTheDoor);
  const [now, setNow] = useState(() => performance.now());
  const call = useRef<AbortController | null>(null);
  const visitId = useRef<string | null>(null);
  const names = useRef(herName);
  useEffect(() => {
    names.current = herName;
  });

  const enter = useCallback(async () => {
    if (!userId || state.stage !== "door") return;
    dispatch({ type: "enter" });
    const controller = new AbortController();
    call.current = controller;
    let her = "";
    try {
      // 量字要用像素字：没载入就量，退回的字体宽度不一样，分页会错。
      await loadPixelFont().catch(() => {});
      for await (const event of enterBar(userId, controller.signal)) {
        if (event.type === "line") {
          const { type: _, ...line } = event;
          const pages = paginate(line, { names: { her, producer: copy.bar.producer }, measure: measurePixelText });
          dispatch({ type: "line", line, pages, now: performance.now() });
        } else {
          if (event.type === "visit") {
            visitId.current = event.visit_id;
            her = names.current(event.character_id);
          }
          dispatch({ type: "event", event });
        }
      }
    } catch (e) {
      if (controller.signal.aborted) return;
      if (visitId.current) return; // 光顾中途断了：票 10。
      if (e instanceof ApiError && e.status === 409) {
        router.push(playHref());
        return;
      }
      const refusal = e instanceof ApiError ? e : { status: 0, message: "", retryAt: null };
      dispatch({ type: "refused", notice: doorNotice(refusal) });
    }
  }, [userId, state.stage, router]);

  const tap = useCallback(() => dispatch({ type: "tap", now: performance.now() }), []);

  /** The visit under way left, its call closed: back at the door. */
  const leave = useCallback(() => {
    call.current?.abort();
    call.current = null;
    const id = visitId.current;
    visitId.current = null;
    if (id) void leaveBarVisit(id).catch(() => {});
    dispatch({ type: "left" });
  }, []);

  // 换到别的页（离开、浏览器返回）时离开；关页面、刷新时也发一个（keepalive 的）DELETE。
  useEffect(() => {
    const onPageHide = () => {
      const id = visitId.current;
      if (id) void leaveBarVisit(id, { keepalive: true }).catch(() => {});
    };
    window.addEventListener("pagehide", onPageHide);
    return () => {
      window.removeEventListener("pagehide", onPageHide);
      call.current?.abort();
      const id = visitId.current;
      if (id) void leaveBarVisit(id).catch(() => {});
    };
  }, []);

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

  return { state, now, enter, tap, leave };
}
