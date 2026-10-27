// A visit to the bar as the screen shows it (.scratch/bar-room spec「接光顾的接口」): the server's
// events of the visit (`POST /api/bar/visits` and the calls after it) and the player's taps,
// reduced to what is on the screen. Pure: the screen draws it and keeps the time (`now`, in ms).
//
// - Her lines and the producer's are queued in the order they come, each laid out in pages
//   (lib/barText). A page types out at 30 characters a second, a tap types it out at once; a
//   tap on a page typed out turns to the next. With no page left while the call is still going,
//   the box waits, and the next line shows as soon as it comes.
// - Once her order line (its last page) is tapped past, typed out, and she is `waiting`, the bar
//   counter opens and the text box says the order memo instead of her line (the original's
//   bartender thinking the order over); the two may come either way round. Typed out, her order
//   stays on the box, the arrow bobbing, till the player has read it and taps, as in the original
//   (the bartender's own line comes between her order and the mixing).
// - Her mood is that of the line of hers on the box; her mouth moves while it types out.
// - While the counter is open the player mixes (lib/barMixer, empty as it opens) and serves: the
//   counter locks while `POST …/serves` is under way; taken, it closes, poured out, and the next line (the
//   producer's 「请慢用」) shows as soon as it comes; refused as broken (422), the shaker shows
//   it broken; the visit gone (410), back at the door; anything else (409 for a double tap), as
//   it was.
// - Each line is marked with the call that sent it. A call made again (`retrying`), or tried
//   again after `failed` once the server took it, has its lines cleared, typed or not, and the box
//   goes back to the page before them: the producer's 「请慢用」 of a drink served is sent before
//   its call is written, so it stays.
// - Failed, the box says the event's message and 「再试一次」; while `POST …/retry` is under way it
//   is locked; refused as gone (410), back at the door; anything else (409 `not_failed`), as it was.
// - Done (`done`), the end card shows once her last page is tapped past: 「再营业」 awaits the next
//   guest inside (`next`), not at the door.
// - The visit gone (a call cut off part-way), back at the door, saying so.

import { copy } from "@/i18n";
import type { ApiError } from "@/lib/api";
import { type BarMixerAction, type BarMixerState, barMixer, canServe, emptyMixer } from "@/lib/barMixer";
import { isTypedOut, shownRows, type TextPage, type TextRow, typedChars, type Typing } from "@/lib/barText";
import type { Emotion } from "@/lib/standAnimations";

/** One line of a visit, as a `line` event brings it. */
export type VisitLine =
  | { speaker: "her"; emotion: Emotion; ja: string; zh: string; order?: true }
  | { speaker: "producer"; zh: string };

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

/** A page of a line queued for the text box, whether it is the line's last, and which of the
 * visit's calls sent it (`BarVisitState.call`). */
type LinePage = { line: VisitLine; page: TextPage; isLast: boolean; call: number };

/** A page on the text box, and how far it has typed. */
type ShownPage = LinePage & { typing: Typing };

export type BarVisitState = {
  /** Outside (`door`), coming in while `POST /api/bar/visits` is under way (`entering`), or in;
   * `next`: in, the next guest awaited after 「再营业」 (`POST /api/bar/visits` under way). */
  stage: "door" | "entering" | "next" | "visit";
  /** At the door: why the last try to come in did not get in. */
  notice: string | null;
  /** The visit under way: its id, and who came in. */
  visit: { id: string; characterId: string } | null;
  /** The page on the text box, and how far it has typed. */
  shown: ShownPage | null;
  /** Pages come and not yet shown, in order. */
  queue: LinePage[];
  /** The player tapped past the last page: the next to come shows at once. */
  isAwaitingLine: boolean;
  /** The call under way, counted from the visit's first: its lines are cleared when it is made
   * again (`retrying`, or tried again after `failed`). */
  call: number;
  /** The next line is the producer's 「请慢用」 a drink taken begins its call with: sent once, before
   * the call is written, so not cleared with it. */
  isEnjoyNext: boolean;
  /** The last page shown before the call under way's, and her mood then: the box and her mood go
   * back to them as the call's lines are cleared. */
  resume: { shown: ShownPage; mood: Emotion } | null;
  /** Her order line is tapped past, the bar counter waiting for `waiting` to open. */
  isOrderRead: boolean;
  /** She is waiting for her drink, the bar counter waiting for her order line to be tapped past. */
  isWaiting: boolean;
  /** The order memo come with her order, shown once the bar counter opens. */
  pendingMemo: string | null;
  /** The order memo of the drink being mixed: the text box says it while the counter is open. */
  memo: string | null;
  /** The bar counter is open (mixing her drink): she waits for it. */
  isMixing: boolean;
  /** Her mood: of the last line of hers on the box; calm as she comes in. */
  mood: Emotion;
  /** The bar counter's shaker. */
  mixer: BarMixerState;
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
    shown: null,
    queue: [],
    isAwaitingLine: false,
    call: 0,
    isEnjoyNext: false,
    resume: null,
    isOrderRead: false,
    isWaiting: false,
    pendingMemo: null,
    memo: null,
    isMixing: false,
    mood: "calm",
    mixer: emptyMixer(),
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
      const pages: LinePage[] = action.pages.map((page, i) => ({
        line: action.line,
        page,
        isLast: i === action.pages.length - 1,
        call: state.call,
      }));
      const call = state.isEnjoyNext ? state.call + 1 : state.call;
      const queued = { ...state, queue: [...state.queue, ...pages], call, isEnjoyNext: false };
      return state.shown === null || state.isAwaitingLine ? showNext(queued, action.now) : queued;
    }
    case "event":
      return onEvent(state, action.event);
    case "tap": {
      const { shown } = state;
      if (!shown || state.failure !== null) return state;
      if (!isTypedOut(shown.page, shown.typing, action.now)) {
        return { ...state, shown: { ...shown, typing: { ...shown.typing, finished: true } } };
      }
      const next =
        state.queue.length > 0 ? showNext(state, action.now) : state.isAwaitingLine ? state : { ...state, isAwaitingLine: true };
      // 她的点单句读完、点过去了：等 `waiting` 一到（或者已经到了）就开调酒台。上过酒以后框上还是那句，再点不算。
      const isRead = isOrderPage(shown) && !state.isMixing && !state.isEnjoyNext;
      return isRead ? openCounter({ ...next, isOrderRead: true }) : next;
    }
    case "mix": {
      if (!state.isMixing || state.isServing) return state;
      const mixer = barMixer(state.mixer, action.action);
      return mixer === state.mixer ? state : { ...state, mixer };
    }
    case "serve":
      return state.isMixing && !state.isServing && canServe(state.mixer) ? { ...state, isServing: true } : state;
    case "served":
      // 调酒时箭头不显示，玩家没理由去点：「请慢用」一到就顶掉点单句开始打。
      return state.isServing
        ? { ...state, isServing: false, isMixing: false, isAwaitingLine: true, isEnjoyNext: true, mixer: emptyMixer() }
        : state;
    case "serveRefused":
      if (!state.isServing) return state;
      if (action.status === 410) return visitGone();
      if (action.status === 422) {
        return { ...state, isServing: false, mixer: barMixer(state.mixer, { type: "broken", garble: action.garble }) };
      }
      return { ...state, isServing: false };
  }
}

function onEvent(state: BarVisitState, event: Exclude<VisitEvent, { type: "line" }>): BarVisitState {
  switch (event.type) {
    case "visit":
      return { ...atTheDoor(), stage: "visit", visit: { id: event.visit_id, characterId: event.character_id } };
    case "memo":
      return { ...state, pendingMemo: event.text };
    case "waiting":
      return openCounter({ ...state, isWaiting: true });
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

/** The next page queued put on the box, typing from `now`. */
function showNext(state: BarVisitState, now: number): BarVisitState {
  const [next, ...queue] = state.queue;
  if (!next) return state;
  const { shown } = state;
  const resume = shown && shown.call !== state.call ? { shown, mood: state.mood } : state.resume;
  const mood = next.line.speaker === "her" ? next.line.emotion : state.mood;
  return {
    ...state,
    shown: { ...next, typing: { startedAt: now, finished: false } },
    queue,
    isAwaitingLine: false,
    isOrderRead: false,
    mood,
    resume,
  };
}

/** The lines the call under way sent cleared, typed or not: the box back on the page before them,
 * typed out, the next line to come shown at once. */
function clearCall(state: BarVisitState): BarVisitState {
  const queue = state.queue.filter((p) => p.call !== state.call);
  if (state.shown?.call !== state.call) return { ...state, queue };
  const { resume } = state;
  return {
    ...state,
    queue,
    shown: resume && { ...resume.shown, typing: { ...resume.shown.typing, finished: true } },
    mood: resume?.mood ?? "calm",
    isAwaitingLine: true,
  };
}

/** The last page of her order line. */
function isOrderPage(page: LinePage): boolean {
  return page.line.speaker === "her" && page.line.order === true && page.isLast;
}

/** The bar counter opened, with her order memo, once her order is tapped past and she waits. */
function openCounter(state: BarVisitState): BarVisitState {
  if (!state.isOrderRead || !state.isWaiting) return state;
  return {
    ...state,
    isOrderRead: false,
    isWaiting: false,
    isMixing: true,
    memo: state.pendingMemo ?? state.memo,
    pendingMemo: null,
  };
}

/** The text box at `now`: whose line, its rows as far as typed, and whether it is typed out. */
export function shownText(
  state: BarVisitState,
  now: number,
): { line: VisitLine; rows: TextRow[]; isTypedOut: boolean } | null {
  const { shown } = state;
  if (!shown) return null;
  return {
    line: shown.line,
    rows: shownRows(shown.page, typedChars(shown.page, shown.typing, now)),
    isTypedOut: isTypedOut(shown.page, shown.typing, now),
  };
}

/** What the text box says while the bar counter is open (her drink being mixed): the order memo,
 * the producer's note to self, whole at once; null otherwise, or with no memo come. */
export function mixingMemo(state: BarVisitState): string | null {
  return state.isMixing ? state.memo : null;
}

/** Whose line is typing out on the box (its typing sound plays meanwhile); null for none. */
export function typingVoice(state: BarVisitState, now: number): VisitLine["speaker"] | null {
  const { shown } = state;
  if (!shown || state.failure !== null || isTypedOut(shown.page, shown.typing, now)) return null;
  return shown.line.speaker;
}

/** Her mouth moves: a line of hers is typing out on the box. */
export function isSpeaking(state: BarVisitState, now: number): boolean {
  return typingVoice(state, now) === "her";
}

/** The arrow at the box's corner bobs: the page is typed out and a tap turns to something, not
 * while the box waits for the next line, nor while she waits for her drink. */
export function isArrowShown(state: BarVisitState, now: number): boolean {
  const { shown } = state;
  if (!shown || state.isAwaitingLine || state.isMixing || state.failure !== null) return false;
  return isTypedOut(shown.page, shown.typing, now);
}

/** The end card, once she said goodbye and her last page is tapped past: whether it says a draw
 * chance came (the day's first visit done) and her affinity rose; neither, it says she left. */
export function endCard(state: BarVisitState): { draws: boolean; affinityUp: boolean } | null {
  const { done } = state;
  if (!done || state.queue.length > 0 || (state.shown !== null && !state.isAwaitingLine)) return null;
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
