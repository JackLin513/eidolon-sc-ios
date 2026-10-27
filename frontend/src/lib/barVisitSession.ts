// A visit to the bar as it talks to the server (.scratch/bar-room spec「接光顾的接口」), kept outside
// React as the conversation page's LiveConversation is: the visit's state (lib/barVisit) moved on
// by the server's events and the player's taps, the screen only reading a snapshot of it.
//
// - Coming in, serving and trying again are one shape of call: the server's answer awaited first,
//   a refusal thrown (with its status), and once taken, the call's events followed as they come.
//   A call taken that ends before `waiting`, `failed` or `done` was cut off: back at the door, the
//   visit gone with it.
// - One call at a time: a new one closes the last, and whatever comes of a call no longer the
//   current one (a late error of the last guest's after 「再营业」) is dropped.
// - Coming in refused while the bar is closed (409), told (`onClosed`); refused otherwise, the
//   door says why. Serving refused, or trying again, goes to lib/barVisit (410: back at the door).
// - Left (or closed as the page goes away), the call is closed and the server leaves the visit:
//   not once the visit is gone (410, a call cut off) or she said goodbye (`done`).

import { ApiError, type Character } from "@/lib/api";
import { type BarMixerAction, garble, served, type ServedBody } from "@/lib/barMixer";
import { isCounterOpen } from "@/lib/barScene";
import type { TextLine, TextPage } from "@/lib/barText";
import { type BarVisitAction, type BarVisitState, atTheDoor, barVisit, doorNotice, endCard, type VisitEvent } from "@/lib/barVisit";

/** The events a call ends on: one ended before them was cut off. */
const LAST_EVENTS: ReadonlySet<VisitEvent["type"]> = new Set(["waiting", "failed", "done"]);

/** A call of the visit's, once the server took it: its events as they come. */
type TakenCall = Promise<AsyncIterable<VisitEvent>>;

/** The sounds the visit plays itself: served (`glassserve`), or nothing servable (`buttonnoclick`). */
export type BarSoundCue = "glassserve" | "buttonnoclick";

/** What the visit needs from outside: the server's calls, laying out her lines, the time, and
 * whom to tell. */
export type BarVisitPorts = {
  enter: (userId: string, signal: AbortSignal) => TakenCall;
  serve: (visitId: string, body: ServedBody, signal: AbortSignal) => TakenCall;
  retry: (visitId: string, signal: AbortSignal) => TakenCall;
  leave: (visitId: string, leaving: { keepalive: boolean }) => Promise<void>;
  /** Lays out a line in pages, with her name: awaited once, on coming in (the pixel font loaded). */
  layOut: () => Promise<(line: TextLine, her: Character | null) => TextPage[]>;
  /** The characters as read so far: who she is, by the `visit` event's `character_id`. */
  characters: () => readonly Character[] | null;
  /** The time now, in ms, as the screen keeps it. */
  now: () => number;
  /** Coming in was refused as the bar is closed. */
  onClosed: () => void;
  /** The visit done gave draw chances (the day's first). */
  onDraws: () => void;
  onSound: (cue: BarSoundCue) => void;
};

/** One visit to the bar at a time, kept outside React; its methods are bound, to be handed to the screen as they are. */
export class BarVisitSession {
  private state: BarVisitState = atTheDoor();
  private listeners = new Set<() => void>();
  /** The call under way, or the last one, until closed: only its events are followed. */
  private call: AbortController | null = null;
  /** The visit the server has under way: left when the visit is. Null before `visit`, and once the
   * visit is gone or done. */
  private visitId: string | null = null;
  private herId = "";
  private pagesFor: Awaited<ReturnType<BarVisitPorts["layOut"]>> | null = null;

  constructor(private readonly ports: BarVisitPorts) {}

  /** A new object only after a change, as `useSyncExternalStore` needs. */
  snapshot = (): BarVisitState => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  /** The door tapped: coming in. Not unless at the door. */
  enter(userId: string): Promise<void> {
    if (this.state.stage !== "door") return Promise.resolve();
    this.dispatch({ type: "enter" });
    return this.comeIn(userId);
  }

  /** 「再营业」 on the end card: the next guest comes in. Not before the end card. */
  again(userId: string): Promise<void> {
    if (!endCard(this.state)) return Promise.resolve();
    this.dispatch({ type: "again" });
    return this.comeIn(userId);
  }

  tap = (): void => {
    this.dispatch({ type: "tap", now: this.ports.now() });
  };

  mix = (action: BarMixerAction): void => {
    this.dispatch({ type: "mix", action });
  };

  /** What is in the shaker served; nothing servable (or the counter closed or locked), only
   * `buttonnoclick`, nothing sent. */
  serve = (): Promise<void> => {
    const { scene, isServing } = this.state;
    const id = this.visitId;
    const body = served(scene.mixer);
    if (!id || !body || !isCounterOpen(scene) || isServing) {
      this.ports.onSound("buttonnoclick");
      return Promise.resolve();
    }
    this.dispatch({ type: "serve" });
    return this.runCall(
      (signal) => this.ports.serve(id, body, signal),
      () => {
        this.ports.onSound("glassserve");
        this.dispatch({ type: "served" });
      },
      (status) => this.dispatch({ type: "serveRefused", status, garble: garble() }),
    );
  };

  /** 「再试一次」: the failed call made again. Not unless it failed, nor while trying again. */
  retry = (): Promise<void> => {
    const { failure, isRetrying } = this.state;
    const id = this.visitId;
    if (!id || failure === null || isRetrying) return Promise.resolve();
    this.dispatch({ type: "retry" });
    return this.runCall(
      (signal) => this.ports.retry(id, signal),
      () => this.dispatch({ type: "retried" }),
      (status) => this.dispatch({ type: "retryRefused", status }),
    );
  };

  /** The visit under way left, its call closed: back at the door. */
  leave = (): void => {
    this.close({ keepalive: false });
    this.dispatch({ type: "left" });
  };

  /** The call under way closed and the visit left, if one is under way (`keepalive` as the page
   * goes away). What is shown stays. */
  close(leaving: { keepalive: boolean }): void {
    this.call?.abort();
    this.call = null;
    const id = this.visitId;
    this.visitId = null;
    if (id) void this.ports.leave(id, leaving).catch(() => {});
  }

  /** `POST /api/bar/visits` and its call followed: from the door, or for the next guest. */
  private comeIn(userId: string): Promise<void> {
    this.visitId = null;
    this.herId = "";
    return this.runCall(
      async (signal) => {
        this.pagesFor ??= await this.ports.layOut();
        return this.ports.enter(userId, signal);
      },
      () => {},
      (status, error) => {
        if (status === 409) this.ports.onClosed();
        else this.dispatch({ type: "refused", notice: doorNotice(error instanceof ApiError ? error : null) });
      },
    );
  }

  /** One call: the last one closed, the server's answer awaited; refused, `refused` with its
   * status (null for no answer at all; the visit gone at 410); taken, `taken`, then its events
   * followed. Whatever comes once it is no longer the current call is dropped. */
  private async runCall(
    request: (signal: AbortSignal) => TakenCall,
    taken: () => void,
    refused: (status: number | null, error: unknown) => void,
  ): Promise<void> {
    this.call?.abort();
    const controller = new AbortController();
    this.call = controller;
    const isCurrent = () => this.call === controller;
    let events: AsyncIterable<VisitEvent>;
    try {
      events = await request(controller.signal);
    } catch (e) {
      if (!isCurrent()) return;
      const status = e instanceof ApiError ? e.status : null;
      if (status === 410) this.visitId = null;
      refused(status, e);
      return;
    }
    if (!isCurrent()) return;
    taken();
    let isEnded = false;
    try {
      for await (const event of events) {
        if (!isCurrent()) return;
        isEnded = LAST_EVENTS.has(event.type);
        this.onEvent(event);
      }
    } catch {
      isEnded = false;
    }
    if (isCurrent() && !isEnded) this.cutOff();
  }

  private onEvent(event: VisitEvent): void {
    if (event.type === "line") {
      const { type: _, ...line } = event;
      const her = this.ports.characters()?.find((c) => c.id === this.herId) ?? null;
      // 分页的函数进门时就等到了（comeIn），上酒、再试一次都在进门以后。
      this.dispatch({ type: "line", line, pages: this.pagesFor!(line, her), now: this.ports.now() });
      return;
    }
    if (event.type === "visit") {
      this.visitId = event.visit_id;
      this.herId = event.character_id;
    }
    if (event.type === "done") {
      this.visitId = null; // 光顾已经结束，离开时不用再离开一次。
      if ((event.rewarded?.draws ?? 0) > 0) this.ports.onDraws();
    }
    this.dispatch({ type: "event", event });
  }

  /** The visit's call cut off part-way: back at the door, the visit gone with it. */
  private cutOff(): void {
    this.call = null;
    this.visitId = null;
    this.dispatch({ type: "gone" });
  }

  private dispatch(action: BarVisitAction): void {
    const state = barVisit(this.state, action);
    if (state === this.state) return;
    this.state = state;
    for (const listener of this.listeners) listener();
  }
}
