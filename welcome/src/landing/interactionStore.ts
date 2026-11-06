// 落地页的交互状态（model/interaction.ts 的 reducer）放在这里，光谱（点偶像听招呼、声音开关）和第 4 幕
// （接听、开场白）共用一份：声音开关管着两边，同时也只能有一种声音。舞台的循环每帧从这里读来电接到了哪一步。
//
// `dispatch` 同步算出新状态并返回它：手机浏览器只认用户手势里发起的播放，点击的处理函数要当场知道
// 该不该出声。订阅者拿到变化前后的两份状态，接通音、开场白按这两份决定，不会因为
// React 合并了几次更新而漏掉一步。

import { useSyncExternalStore } from "react";

import { INITIAL, interactionReducer, type Interaction, type InteractionAction } from "./model/interaction";

type Listener = (prev: Interaction, next: Interaction) => void;

let state: Interaction = INITIAL;
const listeners = new Set<Listener>();

export const interactionStore = {
  get: (): Interaction => state,
  dispatch(action: InteractionAction): Interaction {
    const prev = state;
    state = interactionReducer(prev, action);
    if (state !== prev) listeners.forEach((l) => l(prev, state));
    return state;
  },
  subscribe(listener: Listener) {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  },
};

const getServer = () => INITIAL;

export function useInteraction(): Interaction {
  return useSyncExternalStore(interactionStore.subscribe, interactionStore.get, getServer);
}
