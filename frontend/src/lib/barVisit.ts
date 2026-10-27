// A visit to the bar as the screen shows it (.scratch/bar-room spec「接光顾的接口」): the server's
// events of the visit (`POST /api/bar/visits` and the calls after it) and the player's taps,
// reduced to what is on the screen. Pure: the screen draws it and keeps the time (`now`, in ms).
//
// - The text box, her mood and the bar counter are the scene's (lib/barScene), fed the visit's
//   lines as they come; what is the visit's own is kept here.
// - Her order line opens the bar counter once tapped past and she is `waiting`, with the order
//   memo come with her order (the original's bartender thinking the order over).
// - While the counter is open the player mixes and serves: the counter locks while `POST …/serves`
//   is under way; taken, the scene stows it and the next line (the producer's 「请慢用」) shows as
//   soon as it comes; refused as broken (422), the shaker shows it broken; the visit gone (410),
//   back at the door; anything else (409 for a double tap), as it was.
// - Each line is marked with the call that sent it. A call made again (`retrying`), or tried
//   again after `failed` once the server took it, has its lines cleared from the scene: the
//   producer's 「请慢用」 of a drink served is sent before its call is written, so it stays.
// - Failed, the box says the event's message and 「再试一次」, a tap on it doing nothing; while
//   `POST …/retry` is under way it is locked; refused as gone (410), back at the door; anything
//   else (409 `not_failed`), as it was.
// - Done (`done`), the end card shows once her last page is tapped past: 「再营业」 awaits the next
//   guest inside (`next`), not at the door.
// - The visit gone (a call cut off part-way), back at the door, saying so.

import { copy } from "@/i18n";
import type { ApiError } from "@/lib/api";
import { type BarMixerAction, canServe } from "@/lib/barMixer";
import { awaitsLine, type BarSceneState, barScene, emptyScene, isCounterOpen, type SceneLine } from "@/lib/barScene";
import type { TextPage } from "@/lib/barText";

/** One line of a visit, as a `line` event brings it: hers may be her order. */
export type VisitLine =
  | (Extract<SceneLine, { speaker: "her" }> & { order?: true })
  | Extract<SceneLine, { speaker: "producer" }>;

/** What a visit done was rewarded with (null for nothing). */
export type VisitRewarded = { draws: number; affinity_up: boolean } | null;

/** The server-sent events of a visit's calls (backend `bar.BarEvent`). */
export type VisitEvent =
  | { type: "visit"; visit_id: string; character_id: string }
  | ({ type: "line" } & VisitLine)
  | { type: "memo"; text: string }
  | { type: "waiting" }
  | { type: "retrying" }
  | { type: "failed"; message: string }
  | { type: "done"; rewarded: VisitRewarded };

export type BarVisitState = {
  /** Outside (`door`), coming in while `POST /api/bar/visits` is under way (`entering`), or in;
   * `next`: in, the next guest awaited after 「再营业」 (`POST /api/bar/visits` under way). */
  stage: "door" | "entering" | "next" | "visit";
  /** At the door: why the last try to come in did not get in. */
  notice: string | null;
  /** The visit under way: its id, and who came in. */
  visit: { id: string; characterId: string } | null;
  /** The text box, her mood and the bar counter. */
  scene: BarSceneState;
  /** The call under way, counted from the visit's first: it marks the lines it sends, cleared
   * when it is made again (`retrying`, or tried again after `failed`). */
  call: number;
  /** The next line is the producer's 「请慢用」 a drink taken begins its call with: sent once, before
   * the call is written, so not cleared with it. */
  isEnjoyNext: boolean;
  /** The order memo come with her order, given the scene as she waits. */
  pendingMemo: string | null;
  /** What is in the shaker is being served (`POST …/serves` under way): the counter is locked. */
  isServing: boolean;
  /** The call under way failed (`failed`): what the text box says instead, with 「再试一次」. */
  failure: string | null;
  /** 「再试一次」 tapped: `POST …/retry` under way. */
  isRetrying: boolean;
  /** She said goodbye (`done`): what the visit was rewarded with; the end card shows once her
   * last page is tapped past. */
  done: { rewarded: VisitRewarded } | null;
};

export type BarVisitAction =
  /** The door tapped: `POST /api/bar/visits` sent. */
  | { type: "enter" }
  /** Coming in was refused; `notice` (`doorNotice`) says why. */
  | { type: "refused"; notice: string }
  /** A line come, laid out in pages (lib/barText `paginate`). */
  | { type: "line"; line: VisitLine; pages: TextPage[]; now: number }
  /** Any other event of a visit's call. */
  | { type: "event"; event: Exclude<VisitEvent, { type: "line" }> }
  /** The text box tapped. */
  | { type: "tap"; now: number }
  /** The visit left: back at the door, the visit gone. */
  | { type: "left" }
  /** 「再营业」 on the end card: `POST /api/bar/visits` sent for the next guest. */
  | { type: "again" }
  /** 「再试一次」 tapped: `POST …/retry` sent. */
  | { type: "retry" }
  /** The server took the retry: the failed call made again from its first line. */
  | { type: "retried" }
  /** The server refused the retry, with this status (null: no answer at all). */
  | { type: "retryRefused"; status: number | null }
  /** The visit is gone: a call refused as gone (410), or cut off part-way. */
  | { type: "gone" }
  /** Something done at the open bar counter. */
  | { type: "mix"; action: BarMixerAction }
  /** What is in the shaker served: `POST …/serves` sent. */
  | { type: "serve" }
  /** The server took what was served: its call (her reaction) under way. */
  | { type: "served" }
  /** The server refused what was served, with this status (null: no answer at all); `garble` is
   * what the slot says if it is broken. */
  | { type: "serveRefused"; status: number | null; garble: string };

export function atTheDoor(): BarVisitState {
  return {
    stage: "door",
    notice: null,
    visit: null,
    scene: emptyScene(),
    call: 0,
    isEnjoyNext: false,
    pendingMemo: null,
    isServing: false,
    failure: null,
    isRetrying: false,
    done: null,
  };
}

/** Back at the door, saying the visit is gone. */
function visitGone(): BarVisitState {
  return { ...atTheDoor(), notice: copy.bar.visitGone };
}

export function barVisit(state: BarVisitState, action: BarVisitAction): BarVisitState {
  switch (action.type) {
    case "enter":
      return state.stage === "door" ? { ...atTheDoor(), stage: "entering" } : state;
    case "again":
      return endCard(state) ? { ...atTheDoor(), stage: "next" } : state;
    case "refused":
      return { ...atTheDoor(), notice: action.notice };
    case "left":
      return atTheDoor();
    case "gone":
      return visitGone();
    case "retry":
      return state.failure !== null && !state.isRetrying ? { ...state, isRetrying: true } : state;
    case "retried":
      return state.isRetrying ? { ...clearCall(state), failure: null, isRetrying: false } : state;
    case "retryRefused":
      if (!state.isRetrying) return state;
      return action.status === 410 ? visitGone() : { ...state, isRetrying: false };
    case "line": {
      const { line, pages, now } = action;
      const opensCounter = line.speaker === "her" && line.order === true;
      const scene = barScene(state.scene, { type: "line", line, pages, now, mark: state.call, opensCounter });
      const call = state.isEnjoyNext ? state.call + 1 : state.call;
      return { ...state, scene, call, isEnjoyNext: false };
    }
    case "event":
      return onEvent(state, action.event);
    case "tap":
      return state.failure !== null ? state : withScene(state, barScene(state.scene, action));
    case "mix":
      return state.isServing ? state : withScene(state, barScene(state.scene, action));
    case "serve": {
      const { scene } = state;
      return isCounterOpen(scene) && !state.isServing && canServe(scene.mixer) ? { ...state, isServing: true } : state;
    }
    case "served":
      return state.isServing
        ? { ...state, isServing: false, isEnjoyNext: true, scene: barScene(state.scene, { type: "stow" }) }
        : state;
    case "serveRefused": {
      if (!state.isServing) return state;
      if (action.status === 410) return visitGone();
      if (action.status !== 422) return { ...state, isServing: false };
      const scene = barScene(state.scene, { type: "mix", action: { type: "broken", garble: action.garble } });
      return { ...state, isServing: false, scene };
    }
  }
}

function onEvent(state: BarVisitState, event: Exclude<VisitEvent, { type: "line" }>): BarVisitState {
  switch (event.type) {
    case "visit":
      return { ...atTheDoor(), stage: "visit", visit: { id: event.visit_id, characterId: event.character_id } };
    case "memo":
      return { ...state, pendingMemo: event.text };
    case "waiting":
      return { ...state, pendingMemo: null, scene: barScene(state.scene, { type: "counterReady", memo: state.pendingMemo }) };
    case "retrying":
      return clearCall(state);
    case "failed":
      return { ...state, failure: event.message };
    case "done":
      return { ...state, done: { rewarded: event.rewarded } };
    default:
      return state;
  }
}

/** The state with `scene`: itself if the scene did not change. */
function withScene(state: BarVisitState, scene: BarSceneState): BarVisitState {
  return scene === state.scene ? state : { ...state, scene };
}

/** The lines the call under way sent cleared from the scene. */
function clearCall(state: BarVisitState): BarVisitState {
  return { ...state, scene: barScene(state.scene, { type: "clear", mark: state.call }) };
}

/** The end card, once she said goodbye and her last page is tapped past: whether it says a draw
 * chance came (the day's first visit done) and her affinity rose; neither, it says she left. */
export function endCard(state: BarVisitState): { draws: boolean; affinityUp: boolean } | null {
  const { done } = state;
  if (!done || !awaitsLine(state.scene)) return null;
  return { draws: (done.rewarded?.draws ?? 0) > 0, affinityUp: done.rewarded?.affinity_up ?? false };
}

/** What the door says when coming in was refused (other than the bar being closed, which goes
 * back to the play page), as a text turn says when it can go on: over this hour's limit, when to
 * come back, in local time to the minute, never early, with the date if not today; set to the
 * user's own keys only (no time to wait for), the server's own words; anything else (null: no
 * answer at all), a short line, and the door may be tapped again. */
export function doorNotice(error: ApiError | null, now = new Date()): string {
  const t = copy.bar.door;
  if (error?.status !== 429) return t.failed;
  if (error.retryAt === null) return error.message;
  const exact = Date.parse(error.retryAt);
  if (isNaN(exact)) return error.message;
  const at = new Date(Math.ceil(exact / 60_000) * 60_000);
  const time = at.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });
  const day = at.toDateString() === now.toDateString() ? "" : `${at.getMonth() + 1}月${at.getDate()}日 `;
  return t.overLimit(`${day}${time}`);
}
