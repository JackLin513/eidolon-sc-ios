"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { toFailure, type Failure } from "@/lib/failure";
import { getGiftCatalog, getGiftState, type GiftInfo, type GiftState } from "@/lib/gifts";
import { later } from "@/lib/seenOnDevice";

/**
 * 玩法页第一级和两个子页共用的状态读取：读礼物状态（有的还读礼物目录，`withCatalog`），读到的告诉外壳（开关和最近一次到账；
 * 在礼物子页上就记成看过，其余的页面上点还在），别处（通话里、别的设备、别的标签页）到账了读到的落后了就重读一遍。
 * 各页自己在 `setState` 里按送礼、抽奖的返回改状态；`failure` 是读不到时的失败。
 */
export function usePlayState({ withCatalog }: { withCatalog: boolean }) {
  const { giftsRead, rewardedAt } = useDirectory();
  const [state, setState] = useState<GiftState | null>(null);
  const [catalog, setCatalog] = useState<GiftInfo[] | null>(null);
  const [failure, setFailure] = useState<Failure | null>(null);

  /** 读到的礼物状态：页面照它显示，开关和最近一次到账也告诉外壳。 */
  const applyGiftState = useCallback(
    (s: GiftState) => {
      setState(s);
      giftsRead(s);
    },
    [giftsRead],
  );

  // 别处到账了，这里读到的落后了：重读一遍，页面跟着更新。每个时刻只重读一次。
  const rereadFor = useRef<string | null>(null);
  useEffect(() => {
    if (!state || !rewardedAt || later(state.rewarded_at, rewardedAt) === state.rewarded_at) return;
    if (rereadFor.current === rewardedAt) return;
    rereadFor.current = rewardedAt;
    getGiftState().then(applyGiftState, () => {});
  }, [state, rewardedAt, applyGiftState]);

  useEffect(() => {
    Promise.all([getGiftState(), withCatalog ? getGiftCatalog() : null]).then(
      ([s, c]) => {
        applyGiftState(s);
        if (c) setCatalog(c);
      },
      (e) => setFailure(toFailure(e)),
    );
  }, [applyGiftState, withCatalog]);

  return { state, setState, catalog, failure, setFailure, applyGiftState };
}
