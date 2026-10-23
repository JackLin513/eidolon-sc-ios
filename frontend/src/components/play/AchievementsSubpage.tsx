"use client";

import { useEffect, useRef, useState } from "react";

import { FailureNotice } from "@/components/app/FailureNotice";
import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { AchievementsSection } from "@/components/gifts/AchievementsSection";
import { PlayClosed, PlayShell, PlaySubpageHeader } from "@/components/play/PlayShell";
import { usePlayState } from "@/components/play/usePlayState";
import { copy } from "@/i18n";
import {
  achievementsSeenUpTo,
  keepAchievementsSeenUpTo,
  latestUnlock,
  OF_ALL,
  unseenRows,
} from "@/lib/achievements";
import { playTitle } from "@/lib/playCards";

const NONE: ReadonlySet<string> = new Set();

/**
 * 「成就」子页（`/play/achievements`，DESIGN.md「玩法页」）：页首返回键回玩法页，下面是合起来的四个成就（解锁晚于进这个子页前
 * 看过的那几行带点，离开这个子页记成看过）。好感度和礼物没开放时页首下面是「玩法暂时没有开放」。
 */
export function AchievementsSubpage() {
  const { state, failure } = usePlayState({ withCatalog: false });
  const { account } = useDirectory();
  const userId = account?.id ?? null;
  // 进这个子页前这台设备上看过的合起来的成就：那一小节里解锁晚于它的带点，留到离开这个子页。
  const [seen, setSeen] = useState<{ userId: string; at: string | null } | null>(null);
  if (userId && seen?.userId !== userId) setSeen({ userId, at: achievementsSeenUpTo(userId, OF_ALL) });

  // 离开这个子页（卸下）时把看过记成合起来的成就里最近一次解锁。
  const latestOfAll = useRef<string | null>(null);
  useEffect(() => {
    latestOfAll.current = state?.achievements ? latestUnlock({ achievements: state.achievements }) : null;
  }, [state]);
  useEffect(() => {
    if (!userId) return;
    return () => {
      if (latestOfAll.current) keepAchievementsSeenUpTo(userId, OF_ALL, latestOfAll.current);
    };
  }, [userId]);

  return (
    <PlayShell header={<PlaySubpageHeader title={playTitle("achievements")} />}>
      {failure && <FailureNotice failure={failure} />}
      {state === null ? (
        !failure && <p className="text-body text-muted-foreground">{copy.play.loading}</p>
      ) : !state.open ? (
        <PlayClosed />
      ) : (
        state.achievements && (
          <AchievementsSection
            achievements={state.achievements}
            unseen={seen ? unseenRows({ achievements: state.achievements }, seen.at) : NONE}
          />
        )
      )}
    </PlayShell>
  );
}
