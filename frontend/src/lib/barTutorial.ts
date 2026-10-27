// The tutorial (.scratch/bar-room spec「教程」, GLOSSARY.md「教程」): はづき orders two drinks and
// teaches the producer to mix them, her lines and when the bar counter opens as lib/barTutorialLines
// writes them. Not a visit: no call, no model, nothing given. Pure: the screen draws it and keeps
// the time (`now`, in ms), laying lines out in pages for it (`layout`).
//
// - The text box, her mood and the bar counter are the scene's (lib/barScene), fed the tutorial's
//   lines a section at a time: a section's lines all tapped past, the next section's follow.
// - A section that opens the bar counter marks its last line to open it, the counter ready with
//   the lesson's memo for the text box to say: it opens once that line is tapped past (the lesson
//   told and read), as her order line does in a visit.
// - Served, what the shaker made (lib/barMixer's match, made as it stopped) picks her reaction: the
//   drink by its id, or the section's `other`; the scene stows the counter and she reacts at once.
//   A broken one cannot be served, as in a visit.
// - Its lines done, the tutorial ends: to the jukebox setup, or straight to the door with no
//   jukebox (no audio), the jukebox section left out. 「跳过」 ends it at once the same way.
// - Seen (ended, done or skipped) is kept on this device, per user (lib/seenOnDevice); left
//   part-way, it is not.

import { type BarMixerAction, canServe } from "@/lib/barMixer";
import { awaitsLine, type BarSceneState, barScene, emptyScene, isCounterOpen, type SceneLine } from "@/lib/barScene";
import type { TextPage } from "@/lib/barText";
import { TUTORIAL, TUTORIAL_START, type TutorialLine, type TutorialSectionId } from "@/lib/barTutorialLines";
import { keepSeenOnDevice, seenOnDevice } from "@/lib/seenOnDevice";

/** Where the tutorial ends: the jukebox setup, or the door (no jukebox). */
export type TutorialEnd = "jukebox" | "door";

export type BarTutorialState = {
  /** The section whose lines are on the box. */
  section: TutorialSectionId;
  /** There is a jukebox to choose for (audio to play): its section is said, the setup ends it. */
  hasJukebox: boolean;
  /** Each line of each section, laid out in pages. */
  laidOut: Record<TutorialSectionId, { line: SceneLine; pages: TextPage[] }[]>;
  /** Who teaches. */
  characterId: string;
  /** The text box, her mood and the bar counter. */
  scene: BarSceneState;
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

/** A line of the tutorial as the scene's (the producer's mood shows nowhere). */
function asSceneLine(line: TutorialLine): SceneLine {
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
  layout: (line: SceneLine) => TextPage[];
  now: number;
}): BarTutorialState {
  const laidOut = Object.fromEntries(
    Object.entries(TUTORIAL).map(([id, section]) => [
      id,
      section.lines.map((l) => {
        const line = asSceneLine(l);
        return { line, pages: layout(line) };
      }),
    ]),
  ) as BarTutorialState["laidOut"];
  const state = { section: TUTORIAL_START, hasJukebox, laidOut, characterId, scene: emptyScene(), end: null };
  return say(state, TUTORIAL_START, now);
}

export function barTutorial(state: BarTutorialState, action: BarTutorialAction): BarTutorialState {
  if (state.end !== null) return state;
  switch (action.type) {
    case "tap":
      return onward({ ...state, scene: barScene(state.scene, action) }, action.now);
    case "mix": {
      const scene = barScene(state.scene, action);
      return scene === state.scene ? state : { ...state, scene };
    }
    case "serve": {
      const then = TUTORIAL[state.section].then;
      const { mixer } = state.scene;
      if (then.type !== "mixer" || !isCounterOpen(state.scene) || !canServe(mixer)) return state;
      const reaction = then.reactions[mixer.made!.drink.id] ?? then.reactions.other;
      // 上了酒：调酒台收起、杯子倒掉，她的反应马上打。
      return say({ ...state, scene: barScene(state.scene, { type: "stow" }) }, reaction, action.now);
    }
    case "skip":
      return { ...state, end: state.hasJukebox ? "jukebox" : "door" };
  }
}

/** The lines of `section` queued for the box (the first shown at once if the box awaits one); a
 * lesson's last line opens the bar counter, ready with the lesson's memo. */
function say(state: BarTutorialState, section: TutorialSectionId, now: number): BarTutorialState {
  const { then } = TUTORIAL[section];
  const lines = state.laidOut[section];
  const said = lines.reduce(
    (scene, { line, pages }, i) =>
      barScene(scene, { type: "line", line, pages, now, opensCounter: then.type === "mixer" && i === lines.length - 1 }),
    state.scene,
  );
  const scene = then.type === "mixer" ? barScene(said, { type: "counterReady", memo: then.memo }) : said;
  return { ...state, section, scene };
}

/** After a tap: a section's last page tapped past, on to what follows it (a lesson's opens the bar
 * counter, the scene's to do). */
function onward(state: BarTutorialState, now: number): BarTutorialState {
  const { scene } = state;
  const then = TUTORIAL[state.section].then;
  if (then.type === "mixer" || isCounterOpen(scene) || !awaitsLine(scene)) return state;
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
