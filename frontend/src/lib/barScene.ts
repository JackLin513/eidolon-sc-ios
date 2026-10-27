// The bar's scene (.scratch/bar-room spec「文本框和打字」「调酒」): the text box, her mood, the bar
// counter, its shaker and the memo, as a visit (lib/barVisit) and the tutorial (lib/barTutorial)
// both show them. Pure: they feed it lines and taps, the screen draws it and keeps the time (`now`,
// in ms). The door, the calls, failures and the end card are not the scene's.
//
// - Lines are queued in the order they come, each laid out in pages (lib/barText). A page types
//   out at 30 characters a second, a tap types it out at once; a tap on a page typed out turns to
//   the next. With no page left, the box waits, and the next line shows as soon as it comes.
// - The bar counter opens on one rule: the last page of a line marked to open it tapped past (typed
//   out first), and the counter said to be ready, with the memo, the two either way round. It
//   opens empty, the text box saying the memo instead of the line (the producer's note to self);
//   typed out, the line stays on the box, the arrow bobbing, till the player has read it and taps.
// - While the counter is open the player mixes (lib/barMixer). Served, it is stowed: closed, poured
//   out, and the next line shows as soon as it comes.
// - A line may be marked (a visit marks each with the call that sent it). The lines of a mark
//   cleared, typed or not, the box goes back to the page before them, typed out, and her mood to
//   hers then; the next line shows as soon as it comes.
// - Her mood is that of the line of hers on the box; her mouth moves while it types out.

import { type BarMixerAction, type BarMixerState, barMixer, emptyMixer } from "@/lib/barMixer";
import type { TextPage } from "@/lib/barText";
import { isTypedOut, shownRows, type TextRow, typedChars, type Typing } from "@/lib/barText";
import type { Emotion } from "@/lib/standAnimations";

/** One line of the scene: hers, with her mood, or the producer's. */
export type SceneLine =
  | { speaker: "her"; emotion: Emotion; ja: string; zh: string }
  | { speaker: "producer"; zh: string };

/** A page of a line queued for the text box, whether it is the line's last, the line's mark (null:
 * none), and whether the line, tapped past, opens the bar counter. */
type ScenePage = { line: SceneLine; page: TextPage; isLast: boolean; mark: number | null; opensCounter: boolean };

/** A page on the text box, and how far it has typed. */
type ShownPage = ScenePage & { typing: Typing };

export type BarSceneState = {
  /** The page on the text box, and how far it has typed. */
  shown: ShownPage | null;
  /** Pages come and not yet shown, in order. */
  queue: ScenePage[];
  /** The player tapped past the last page: the next to come shows at once. */
  isAwaitingLine: boolean;
  /** Her mood: of the last line of hers on the box; calm as she comes in. */
  mood: Emotion;
  /** The last page shown before the lines of the mark on the box, and her mood then: the box and
   * her mood go back to them as that mark's lines are cleared. */
  resume: { shown: ShownPage; mood: Emotion } | null;
  /** The line that opens the bar counter is tapped past, the counter waiting to be ready. */
  isOpenerRead: boolean;
  /** The counter is ready to open, with this memo (null: the last one's), waiting for the line
   * that opens it to be tapped past. */
  ready: { memo: string | null } | null;
  /** The memo of the drink being mixed: the text box says it while the counter is open. */
  memo: string | null;
  /** The bar counter is open. */
  isMixing: boolean;
  /** The bar counter's shaker. */
  mixer: BarMixerState;
};

export type BarSceneAction =
  /** A line come, laid out in pages (lib/barText `paginate`). */
  | { type: "line"; line: SceneLine; pages: TextPage[]; now: number; mark?: number; opensCounter?: boolean }
  /** The text box tapped. */
  | { type: "tap"; now: number }
  /** The bar counter ready to open, with the memo of the drink to mix (null: the last one's). */
  | { type: "counterReady"; memo: string | null }
  /** Something done at the open bar counter. */
  | { type: "mix"; action: BarMixerAction }
  /** The drink served: the bar counter closed, the shaker poured out, the next line shown at once. */
  | { type: "stow" }
  /** The lines of `mark` cleared, typed or not. */
  | { type: "clear"; mark: number };

export function emptyScene(): BarSceneState {
  return {
    shown: null,
    queue: [],
    isAwaitingLine: false,
    mood: "calm",
    resume: null,
    isOpenerRead: false,
    ready: null,
    memo: null,
    isMixing: false,
    mixer: emptyMixer(),
  };
}

export function barScene(state: BarSceneState, action: BarSceneAction): BarSceneState {
  switch (action.type) {
    case "line": {
      const { line, mark = null, opensCounter = false } = action;
      const pages = action.pages.map((page, i) => ({ line, page, isLast: i === action.pages.length - 1, mark, opensCounter }));
      const queued = { ...state, queue: [...state.queue, ...pages] };
      return state.shown === null || state.isAwaitingLine ? showNext(queued, action.now) : queued;
    }
    case "tap": {
      const { shown } = state;
      if (!shown) return state;
      if (!isTypedOut(shown.page, shown.typing, action.now)) {
        return { ...state, shown: { ...shown, typing: { ...shown.typing, finished: true } } };
      }
      if (state.isAwaitingLine) return state;
      const next = state.queue.length > 0 ? showNext(state, action.now) : { ...state, isAwaitingLine: true };
      // 标了开台的那句读完、点过去了：可以开台的话一到（或者已经到了）就开。
      const isRead = shown.opensCounter && shown.isLast && !state.isMixing;
      return isRead ? openCounter({ ...next, isOpenerRead: true }) : next;
    }
    case "counterReady":
      return openCounter({ ...state, ready: { memo: action.memo } });
    case "mix": {
      if (!state.isMixing) return state;
      const mixer = barMixer(state.mixer, action.action);
      return mixer === state.mixer ? state : { ...state, mixer };
    }
    case "stow":
      // 调酒时箭头不显示，玩家没理由去点：下一句一到就顶掉框上那句开始打。
      return { ...state, isMixing: false, mixer: emptyMixer(), isAwaitingLine: true };
    case "clear":
      return clearMark(state, action.mark);
  }
}

/** The bar counter opened, empty, with its memo, once the line that opens it is tapped past and it
 * is ready. */
function openCounter(state: BarSceneState): BarSceneState {
  if (!state.isOpenerRead || !state.ready) return state;
  return {
    ...state,
    isOpenerRead: false,
    ready: null,
    isMixing: true,
    mixer: emptyMixer(),
    memo: state.ready.memo ?? state.memo,
  };
}

/** The next page queued put on the box, typing from `now`. */
function showNext(state: BarSceneState, now: number): BarSceneState {
  const [next, ...queue] = state.queue;
  if (!next) return state;
  const { shown } = state;
  const resume = shown && shown.mark !== next.mark ? { shown, mood: state.mood } : state.resume;
  const mood = next.line.speaker === "her" ? next.line.emotion : state.mood;
  return {
    ...state,
    shown: { ...next, typing: { startedAt: now, finished: false } },
    queue,
    isAwaitingLine: false,
    isOpenerRead: false,
    mood,
    resume,
  };
}

/** The lines of `mark` cleared, typed or not: the box back on the page before them, typed out, the
 * next line to come shown at once. */
function clearMark(state: BarSceneState, mark: number): BarSceneState {
  const queue = state.queue.filter((p) => p.mark !== mark);
  if (state.shown?.mark !== mark) return { ...state, queue };
  const { resume } = state;
  return {
    ...state,
    queue,
    shown: resume && { ...resume.shown, typing: { ...resume.shown.typing, finished: true } },
    mood: resume?.mood ?? "calm",
    isAwaitingLine: true,
  };
}

/** The text box at `now`: whose line, its rows as far as typed, and whether it is typed out. */
export function shownText(
  state: BarSceneState,
  now: number,
): { line: SceneLine; rows: TextRow[]; isTypedOut: boolean } | null {
  const { shown } = state;
  if (!shown) return null;
  return {
    line: shown.line,
    rows: shownRows(shown.page, typedChars(shown.page, shown.typing, now)),
    isTypedOut: isTypedOut(shown.page, shown.typing, now),
  };
}

/** Whose line is typing out on the box (its typing sound plays meanwhile); null for none. */
export function typingVoice(state: BarSceneState, now: number): SceneLine["speaker"] | null {
  const { shown } = state;
  if (!shown || isTypedOut(shown.page, shown.typing, now)) return null;
  return shown.line.speaker;
}

/** Her mouth moves: a line of hers is typing out on the box. */
export function isSpeaking(state: BarSceneState, now: number): boolean {
  return typingVoice(state, now) === "her";
}

/** The arrow at the box's corner bobs: the page is typed out and a tap turns to something, not
 * while the box waits for the next line, nor while the bar counter is open. */
export function isArrowShown(state: BarSceneState, now: number): boolean {
  const { shown } = state;
  if (!shown || state.isAwaitingLine || state.isMixing) return false;
  return isTypedOut(shown.page, shown.typing, now);
}

/** The bar counter is open. */
export function isCounterOpen(state: BarSceneState): boolean {
  return state.isMixing;
}

/** What the text box says while the bar counter is open: the memo, the producer's note to self,
 * whole at once; null otherwise, or with no memo. */
export function mixingMemo(state: BarSceneState): string | null {
  return state.isMixing ? state.memo : null;
}

/** The box waits for the next line: nothing said yet, or every page come tapped past. */
export function awaitsLine(state: BarSceneState): boolean {
  return state.queue.length === 0 && (state.shown === null || state.isAwaitingLine);
}
