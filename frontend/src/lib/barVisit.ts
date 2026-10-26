// A visit to the bar as the screen shows it (.scratch/bar-room spec「接光顾的接口」): the server's
// events of the visit (`POST /api/bar/visits` and the calls after it) and the player's taps,
// reduced to what is on the screen. Pure: the screen draws it and keeps the time (`now`, in ms).
//
// - Her lines and the producer's are queued in the order they come, each laid out in pages
//   (lib/barText). A page types out at 30 characters a second, a tap types it out at once; a
//   tap on a page typed out turns to the next. With no page left while the call is still going,
//   the box waits, and the next line shows as soon as it comes.
// - Once her order line is typed out (its last page) and she is `waiting`, the order memo shows
//   and the bar counter opens; the two may come either way round.
// - Her mood is that of the line of hers on the box; her mouth moves while it types out.

import { copy } from "@/i18n";
import type { ApiError } from "@/lib/api";
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

/** A page of a line queued for the text box, and whether it is the line's last. */
type LinePage = { line: VisitLine; page: TextPage; isLast: boolean };

export type BarVisitState = {
  /** Outside (`door`), coming in while `POST /api/bar/visits` is under way (`entering`), or in. */
  stage: "door" | "entering" | "visit";
  /** At the door: why the last try to come in did not get in. */
  notice: string | null;
  /** The visit under way: its id, and who came in. */
  visit: { id: string; characterId: string } | null;
  /** The page on the text box, and how far it has typed. */
  shown: (LinePage & { typing: Typing }) | null;
  /** Pages come and not yet shown, in order. */
  queue: LinePage[];
  /** The player tapped past the last page: the next to come shows at once. */
  isAwaitingLine: boolean;
  /** Her order line is typed out, the bar counter waiting for `waiting` to open. */
  isOrderTyped: boolean;
  /** She is waiting for her drink, the bar counter waiting for her order line to be typed out. */
  isWaiting: boolean;
  /** The order memo come with her order, shown once the bar counter opens. */
  pendingMemo: string | null;
  /** The order memo on the side menu; stays till the next. */
  memo: string | null;
  /** The bar counter is open (mixing her drink): she waits for it. */
  isMixing: boolean;
  /** Her mood: of the last line of hers on the box; calm as she comes in. */
  mood: Emotion;
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
  /** The page on the text box may have typed out (the screen ticks then). */
  | { type: "tick"; now: number }
  /** The visit left: back at the door, the visit gone. */
  | { type: "left" };

export function atTheDoor(): BarVisitState {
  return {
    stage: "door",
    notice: null,
    visit: null,
    shown: null,
    queue: [],
    isAwaitingLine: false,
    isOrderTyped: false,
    isWaiting: false,
    pendingMemo: null,
    memo: null,
    isMixing: false,
    mood: "calm",
  };
}

export function barVisit(state: BarVisitState, action: BarVisitAction): BarVisitState {
  switch (action.type) {
    case "enter":
      return state.stage === "door" ? { ...atTheDoor(), stage: "entering" } : state;
    case "refused":
      return { ...atTheDoor(), notice: action.notice };
    case "left":
      return atTheDoor();
    case "line": {
      const pages: LinePage[] = action.pages.map((page, i) => ({
        line: action.line,
        page,
        isLast: i === action.pages.length - 1,
      }));
      const queued = { ...state, queue: [...state.queue, ...pages] };
      return state.shown === null || state.isAwaitingLine ? showNext(queued, action.now) : queued;
    }
    case "event":
      return onEvent(state, action.event);
    case "tap": {
      const { shown } = state;
      if (!shown) return state;
      if (!isTypedOut(shown.page, shown.typing, action.now)) {
        return afterTyping({ ...state, shown: { ...shown, typing: { ...shown.typing, finished: true } } }, action.now);
      }
      if (state.queue.length === 0) return state.isAwaitingLine ? state : { ...state, isAwaitingLine: true };
      return showNext(state, action.now);
    }
    case "tick":
      return afterTyping(state, action.now);
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
    default:
      // retrying、failed、done：票 10。
      return state;
  }
}

/** The next page queued put on the box, typing from `now`. */
function showNext(state: BarVisitState, now: number): BarVisitState {
  const [next, ...queue] = state.queue;
  if (!next) return state;
  const mood = next.line.speaker === "her" ? next.line.emotion : state.mood;
  return afterTyping({ ...state, shown: { ...next, typing: { startedAt: now, finished: false } }, queue, isAwaitingLine: false, mood }, now);
}

/** What follows from the page on the box having typed out by `now`. */
function afterTyping(state: BarVisitState, now: number): BarVisitState {
  const { shown } = state;
  if (!shown || state.isOrderTyped || state.isMixing) return state;
  const isOrder = shown.line.speaker === "her" && shown.line.order === true && shown.isLast;
  if (!isOrder || !isTypedOut(shown.page, shown.typing, now)) return state;
  return openCounter({ ...state, isOrderTyped: true });
}

/** The bar counter opened, with her order memo, once her order is typed out and she waits. */
function openCounter(state: BarVisitState): BarVisitState {
  if (!state.isOrderTyped || !state.isWaiting) return state;
  return { ...state, isOrderTyped: false, isWaiting: false, isMixing: true, memo: state.pendingMemo ?? state.memo, pendingMemo: null };
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

/** Whose line is typing out on the box (its typing sound plays meanwhile); null for none. */
export function typingVoice(state: BarVisitState, now: number): VisitLine["speaker"] | null {
  const { shown } = state;
  return shown !== null && !isTypedOut(shown.page, shown.typing, now) ? shown.line.speaker : null;
}

/** Her mouth moves: a line of hers is typing out on the box. */
export function isSpeaking(state: BarVisitState, now: number): boolean {
  return typingVoice(state, now) === "her";
}

/** The arrow at the box's corner bobs: the page is typed out and a tap turns to something, not
 * while the box waits for the next line, nor while she waits for her drink. */
export function isArrowShown(state: BarVisitState, now: number): boolean {
  const { shown } = state;
  return shown !== null && isTypedOut(shown.page, shown.typing, now) && !state.isAwaitingLine && !state.isMixing;
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
