"use client";

import { FailureNotice } from "@/components/app/FailureNotice";
import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { PlayCardLink } from "@/components/play/PlayCardLink";
import { PlayClosed, PlayHeader, PlayShell } from "@/components/play/PlayShell";
import { usePlayState } from "@/components/play/usePlayState";
import { achievementsSeenUpTo, OF_ALL } from "@/lib/achievements";
import { playCards } from "@/lib/playCards";

/**
 * 玩法页第一级（`/play`，DESIGN.md「玩法页」）：页首「玩法」大标题，下面一张张入口卡；第一张（礼物）铺满一行，其余两列网格、窄屏一列。
 * 读到状态之前卡片就在、状态那一行先空着；读到好感度和礼物没开放时一张卡都没有，只剩「玩法暂时没有开放」。
 * 卡的内容（名字、去哪、状态、点）由 `lib/playCards` 管，这里只管顺序和版式。
 * 只进这一级不算看过：「礼物」卡上的点留着，进了礼物子页才没有；「每日任务与成就」卡上的点留到离开那个子页。
 */
export function PlayPage() {
  const { account, newRewards } = useDirectory();
  const { state, failure } = usePlayState({ withCatalog: false });
  const achievementsSeenAt = account && state ? achievementsSeenUpTo(account.id, OF_ALL) : null;
  const cards = playCards({ state, newRewards, achievementsSeenAt });
  const [first, ...rest] = cards;
  return (
    <PlayShell header={<PlayHeader />}>
      {failure && <FailureNotice failure={failure} />}
      {first ? (
        <>
          <PlayCardLink card={first} isFilled />
          {rest.length > 0 && (
            <div className="grid gap-4 sm:grid-cols-2">
              {rest.map((card) => (
                <PlayCardLink key={card.id} card={card} />
              ))}
            </div>
          )}
        </>
      ) : (
        <PlayClosed />
      )}
    </PlayShell>
  );
}
