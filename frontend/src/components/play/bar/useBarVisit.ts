"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";

import { type CurrentScene, loadSceneLayout } from "@/components/play/bar/sceneOnScreen";
import type { BarSound } from "@/components/play/bar/useBarSound";
import { useTypingClock } from "@/components/play/bar/useTypingClock";
import { type Character, enterBar, leaveBarVisit, retryBarVisit, serveBarDrink } from "@/lib/api";
import { endCard } from "@/lib/barVisit";
import { BarVisitSession } from "@/lib/barVisitSession";
import { playHref } from "@/lib/playRoute";

/**
 * 一次光顾（.scratch/bar-room spec「一次营业的流程」「接光顾的接口」）：把 lib/barVisitSession 接到画面上，交出当前场景（`current`，sceneOnScreen）。
 * 接口调用、中止、迟到的错误、中途断了、409、410 都在会话里；这里只管要在点击里同步做的、计时和页面的事：
 * - 进门那一下响门声、放曲目（useBarSound 要在这一下点击里开始）；「再营业」只响门声。角色读到之前店门口点了不进。
 * - 一页在打字时每个字重画一次（useTypingClock）。
 * - 关着（409）回玩法页；得了抽奖告诉一声（`onDraws`）；上了酒、上不了的音效照会话说的响。
 * - 换到别的页（离开、浏览器返回）时关掉会话；关页面、刷新时带 keepalive 关掉。
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
  // 会话只建一次，它要的角色列表和几个通知照最新的 props 来。
  const latestProps = useRef({ characters, sound, onDraws, router });
  useEffect(() => {
    latestProps.current = { characters, sound, onDraws, router };
  });
  const [session] = useState(
    () =>
      new BarVisitSession({
        enter: enterBar,
        serve: serveBarDrink,
        retry: retryBarVisit,
        leave: leaveBarVisit,
        layOut: loadSceneLayout,
        characters: () => latestProps.current.characters,
        now: () => performance.now(),
        onClosed: () => latestProps.current.router.push(playHref()),
        onDraws: () => latestProps.current.onDraws(),
        onSound: (cue) => latestProps.current.sound.play(cue),
      }),
  );
  const state = useSyncExternalStore(session.subscribe, session.snapshot, session.snapshot);

  const enter = useCallback(() => {
    if (!userId || !characters || session.snapshot().stage !== "door") return;
    sound.start();
    sound.play("door");
    void session.enter(userId);
  }, [userId, characters, sound, session]);

  /** 「再营业」：曲目接着放，下一位进门。 */
  const again = useCallback(() => {
    if (!userId || !endCard(session.snapshot())) return;
    sound.play("door");
    void session.again(userId);
  }, [userId, sound, session]);

  useEffect(() => {
    const onPageHide = () => session.close({ keepalive: true });
    window.addEventListener("pagehide", onPageHide);
    return () => {
      window.removeEventListener("pagehide", onPageHide);
      session.close({ keepalive: false });
    };
  }, [session]);

  const now = useTypingClock(state.scene.shown);
  const { visit } = state;
  const { tap, mix, serve, leave, retry } = session;
  const current = useMemo<CurrentScene>(
    () => ({
      scene: state.scene,
      now,
      guest: visit && { key: visit.id, characterId: visit.characterId },
      tap,
      mix,
      serve,
    }),
    [state.scene, now, visit, tap, mix, serve],
  );

  return { state, current, enter, again, leave, retry };
}
