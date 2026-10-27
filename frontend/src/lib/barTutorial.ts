// The tutorial (.scratch/bar-room spec「教程」, GLOSSARY.md「教程」): はづき orders two drinks and
// teaches the producer to mix them, her lines and when the bar counter opens as lib/barTutorialLines
// writes them. Not a visit: no call, no model, nothing given. Pure: the screen draws it and keeps
// the time (`now`, in ms), laying lines out in pages for it (`layout`).
//
// - The text box, her mood and the bar counter are lib/barVisit's, fed the tutorial's lines a
//   section at a time: a section's lines all tapped past, the next section's follow.
// - A section that opens the bar counter opens it once its last page is tapped past (the lesson
//   told and read), as her order line does in a visit, with the lesson's memo for the text box to
//   say.
// - Served, what the shaker made (lib/barMixer's match, made as it stopped) picks her reaction: the
//   drink by its id, or the section's `other`; then on, whatever was served. A broken one cannot
//   be served, as in a visit.
// - Its lines done, the tutorial ends: to the jukebox setup, or straight to the door with no
//   jukebox (no audio), the jukebox section left out. 「跳过」 ends it at once the same way.
// - Seen (ended, done or skipped) is kept on this device, per user (lib/seenOnDevice); left
//   part-way, it is not.

import { type BarMixerAction, canServe, emptyMixer } from "@/lib/barMixer";
import type { TextPage } from "@/lib/barText";
import { TUTORIAL, TUTORIAL_START, type TutorialLine, type TutorialSectionId } from "@/lib/barTutorialLines";
import { atTheDoor, barVisit, type BarVisitState, type VisitLine } from "@/lib/barVisit";
import { keepSeenOnDevice, seenOnDevice } from "@/lib/seenOnDevice";

/** Where the tutorial ends: the jukebox setup, or the door (no jukebox). */
export type TutorialEnd = "jukebox" | "door";

export type BarTutorialState = {
  /** The section whose lines are on the box. */
  section: TutorialSectionId;
  /** There is a jukebox to choose for (audio to play): its section is said, the setup ends it. */
  hasJukebox: boolean;
  /** Each line of each section, laid out in pages. */
  laidOut: Record<TutorialSectionId, { line: VisitLine; pages: TextPage[] }[]>;
  /** The text box, her mood and the bar counter (lib/barVisit). */
  visit: BarVisitState;
  /** Ended (done or skipped), and to where. */
  end: TutorialEnd | null;
};

export type BarTutorialAction =
  /** The text box tapped. */
  | { type: "tap"; now: number }
  /** Something done at the open bar counter. */
  | { type: "mix"; action: BarMixerAction }
  /** What is in the shaker served. */
  | { type: "serve"; now: number }
  /** 「跳过」 tapped. */
  | { type: "skip" };

/** The tutorial's visit has no id on the server: nothing to leave. */
const TUTORIAL_VISIT_ID = "tutorial";

/** A line of the tutorial as a visit's line (the producer's mood shows nowhere). */
function asVisitLine(line: TutorialLine): VisitLine {
  return line.who === "her"
    ? { speaker: "her", emotion: line.emotion, ja: line.ja, zh: line.zh }
    : { speaker: "producer", zh: line.zh };
}

/** The tutorial from its first line, her (`characterId`) come in. */
export function beginTutorial({
  characterId,
  hasJukebox,
  layout,
  now,
}: {
  characterId: string;
  hasJukebox: boolean;
  layout: (line: VisitLine) => TextPage[];
  now: number;
}): BarTutorialState {
  const laidOut = Object.fromEntries(
    Object.entries(TUTORIAL).map(([id, section]) => [
      id,
      section.lines.map((l) => {
        const line = asVisitLine(l);
        return { line, pages: layout(line) };
      }),
    ]),
  ) as BarTutorialState["laidOut"];
  const visit = barVisit(atTheDoor(), {
    type: "event",
    event: { type: "visit", visit_id: TUTORIAL_VISIT_ID, character_id: characterId },
  });
  return say({ section: TUTORIAL_START, hasJukebox, laidOut, visit, end: null }, TUTORIAL_START, now);
}

export function barTutorial(state: BarTutorialState, action: BarTutorialAction): BarTutorialState {
  if (state.end !== null) return state;
  switch (action.type) {
    case "tap": {
      const visit = barVisit(state.visit, action);
      return onward({ ...state, visit }, action.now);
    }
    case "mix":
      return { ...state, visit: barVisit(state.visit, action) };
    case "serve": {
      const then = TUTORIAL[state.section].then;
      const { mixer } = state.visit;
      if (then.type !== "mixer" || !state.visit.isMixing || !canServe(mixer)) return state;
      const reaction = then.reactions[mixer.made!.drink.id] ?? then.reactions.other;
      // 上了酒：调酒台收起、杯子倒掉，她的反应马上打。
      const visit = { ...state.visit, isMixing: false, isAwaitingLine: true, mixer: emptyMixer() };
      return say({ ...state, visit }, reaction, action.now);
    }
    case "skip":
      return { ...state, end: state.hasJukebox ? "jukebox" : "door" };
  }
}

/** The lines of `section` queued for the box (the first shown at once if the box awaits one). */
function say(state: BarTutorialState, section: TutorialSectionId, now: number): BarTutorialState {
  const visit = state.laidOut[section].reduce(
    (v, { line, pages }) => barVisit(v, { type: "line", line, pages, now }),
    { ...state.visit, isAwaitingLine: true },
  );
  return { ...state, section, visit };
}

/** After a tap: a section's last page tapped past, on to what follows it: the bar counter opened,
 * with the lesson's memo, after a lesson. */
function onward(state: BarTutorialState, now: number): BarTutorialState {
  const { visit } = state;
  if (visit.isMixing || visit.queue.length > 0 || !visit.isAwaitingLine) return state;
  const then = TUTORIAL[state.section].then;
  if (then.type === "mixer") return { ...state, visit: { ...visit, isMixing: true, mixer: emptyMixer(), memo: then.memo } };
  if (then.type === "done") return { ...state, end: "jukebox" };
  if (then.section === "jukebox" && !state.hasJukebox) return { ...state, end: "door" };
  return say(state, then.section, now);
}

function seenKey(userId: string): string {
  return `eidolon.barTutorialSeen.${userId}`;
}

/** This user has seen the tutorial on this device (done or skipped it). */
export function hasSeenTutorial(userId: string): boolean {
  return seenOnDevice(seenKey(userId)) !== null;
}

/** Keeps on this device that this user has seen the tutorial, if it ended (done or skipped); left
 * part-way, it is not seen. */
export function keepTutorialSeen(userId: string, state: BarTutorialState): void {
  if (state.end !== null) keepSeenOnDevice(seenKey(userId), new Date().toISOString());
}
