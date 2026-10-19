"use client";

import { useEffect, useRef } from "react";

type WhileVisibleOptions = {
  /** 再露出来时不论离上次多久都马上调一次（对话列表：切回标签页就要看到这期间她搭的话）。 */
  atOnceWhenShown?: boolean;
};

/**
 * 页面看得见时每隔 `ms` 调一次 `tick`；藏起来（切到别的标签页、锁屏）就不调，再露出来时离上次已过
 * `ms` 就马上补一次（`atOnceWhenShown` 时不论过了多久）。不在看的看板不必每分钟去问后端。`ms` 变了从变的那一刻重新计时。
 */
export function useWhileVisible(tick: () => void, ms: number, { atOnceWhenShown = false }: WhileVisibleOptions = {}) {
  const tickRef = useRef(tick);
  useEffect(() => {
    tickRef.current = tick;
  });
  useEffect(() => {
    let last = Date.now();
    const run = () => {
      last = Date.now();
      tickRef.current();
    };
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") run();
    }, ms);
    const onVisible = () => {
      if (document.visibilityState === "visible" && (atOnceWhenShown || Date.now() - last >= ms)) run();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [ms, atOnceWhenShown]);
}
