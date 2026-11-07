"use client";

import { useEffect } from "react";

import { stageStore, useStage } from "./stageStore";

/**
 * 左侧竖排的日文幕名轨：当前这一幕亮起。当前在哪一幕记在 stageStore 里：运动版式由舞台的循环按落地页模型写，
 * 静止版式（定格档、静态档）没有循环，由这里看页面上哪一幕（`data-lp-act` 的元素）跨过视口的中线。
 * 没有 JS 时停在第 0 幕。
 */
export function Rail({ label, acts }: { label: string; acts: { act: number; name: string }[] }) {
  const { act: current } = useStage();

  useEffect(() => {
    if (document.documentElement.dataset.lpLayout === "motion") return;
    const io = new IntersectionObserver(
      (entries) => {
        const hit = entries.find((e) => e.isIntersecting);
        if (hit) stageStore.set({ act: Number((hit.target as HTMLElement).dataset.lpAct) });
      },
      // 一条横在视口中间的线：跨过它的那一幕就是当前这一幕。
      { rootMargin: "-50% 0px -50% 0px" },
    );
    document.querySelectorAll("[data-lp-act]").forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, []);

  return (
    <nav className="lp-rail" aria-label={label}>
      <ol lang="ja">
        {acts.map(({ act, name }) => (
          <li key={act} data-current={act === current ? "" : undefined} aria-current={act === current ? "step" : undefined}>
            {name}
          </li>
        ))}
      </ol>
    </nav>
  );
}
