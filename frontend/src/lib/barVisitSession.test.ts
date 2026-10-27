import { describe, expect, it } from "vitest";

import { ApiError, type Character, type Drink } from "@/lib/api";
import type { ServedBody } from "@/lib/barMixer";
import { isCounterOpen, mixingMemo, shownText } from "@/lib/barScene";
import { paginate } from "@/lib/barText";
import { type BarSoundCue, BarVisitSession, type BarVisitPorts } from "@/lib/barVisitSession";
import { endCard, type VisitEvent, type VisitLine } from "@/lib/barVisit";
import { copy } from "@/i18n";

/** A call's events as the test sends them: they wait until sent, and may end, or break off. */
class Stream implements AsyncIterable<VisitEvent> {
  private queue: VisitEvent[] = [];
  private ended = false;
  private error: unknown = null;
  private wake: (() => void) | null = null;
  /** The session stopped following it (it was closed, or a newer call took over). */
  returned = false;

  send(...events: VisitEvent[]): void {
    this.queue.push(...events);
    this.poke();
  }
  end(): void {
    this.ended = true;
    this.poke();
  }
  fail(error: unknown = new Error("network")): void {
    this.error = error;
    this.poke();
  }
  private poke(): void {
    this.wake?.();
    this.wake = null;
  }
  async *[Symbol.asyncIterator](): AsyncIterator<VisitEvent> {
    try {
      for (;;) {
        if (this.queue.length > 0) {
          yield this.queue.shift()!;
          continue;
        }
        if (this.error !== null) throw this.error;
        if (this.ended) return;
        await new Promise<void>((resolve) => (this.wake = resolve));
      }
    } finally {
      this.returned = true;
    }
  }
}

/** One call of the session's: the server's answer waits until the test gives it. */
type Request = {
  signal: AbortSignal;
  take: () => Stream;
  refuse: (error: unknown) => void;
};

function pending(signal: AbortSignal, into: Request[]): Promise<AsyncIterable<VisitEvent>> {
  return new Promise((resolve, reject) => {
    into.push({
      signal,
      take: () => {
        const stream = new Stream();
        resolve(stream);
        return stream;
      },
      refuse: reject,
    });
  });
}

/** Ports that record what the session asks of them. */
function fakePorts() {
  const calls = {
    enters: [] as Request[],
    serves: [] as (Request & { visitId: string; body: ServedBody })[],
    retries: [] as (Request & { visitId: string })[],
    leaves: [] as { visitId: string; keepalive: boolean }[],
    closed: 0,
    draws: 0,
    sounds: [] as BarSoundCue[],
  };
  const characters: Character[] = [{ id: "mano", name: "樱木真乃", short_name: "真乃" } as Character];
  const ports: BarVisitPorts = {
    enter: (_userId, signal) => pending(signal, calls.enters),
    serve: (visitId, body, signal) => {
      const serves: Request[] = [];
      const answer = pending(signal, serves);
      calls.serves.push({ ...serves[0], visitId, body });
      return answer;
    },
    retry: (visitId, signal) => {
      const retries: Request[] = [];
      const answer = pending(signal, retries);
      calls.retries.push({ ...retries[0], visitId });
      return answer;
    },
    leave: async (visitId, { keepalive }) => void calls.leaves.push({ visitId, keepalive }),
    layOut: async () => (line, her) =>
      paginate(line, { names: { her: her?.short_name ?? her?.name ?? "", producer: "制作人" }, measure }),
    characters: () => characters,
    now: () => clock,
    onClosed: () => void calls.closed++,
    onDraws: () => void calls.draws++,
    onSound: (cue) => void calls.sounds.push(cue),
  };
  return { ports, calls };
}

/** Every character as wide as a CJK one. */
const measure = (text: string) => [...text].length * 12;
let clock = 0;

/** Lets everything the session awaits settle. */
async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await Promise.resolve();
}

const line = (l: VisitLine): VisitEvent => ({ type: "line", ...l });
const VISIT: VisitEvent = { type: "visit", visit_id: "v1", character_id: "mano" };
const HELLO: VisitLine = { speaker: "her", emotion: "happy", ja: "こんばんは", zh: "晚上好" };
const ORDER: VisitLine = { speaker: "her", emotion: "thinking", ja: "ビールを", zh: "要啤酒", order: true };
const ENJOY: VisitLine = { speaker: "producer", zh: "请慢用" };
const BYE: VisitLine = { speaker: "her", emotion: "happy", ja: "またね", zh: "再见" };
const BEER: Drink = {
  id: "beer",
  name: "Beer",
  short_name: "Beer",
  flavor: "bubbly",
  kind: "classic",
  method: "bottle",
  description: "",
  karmotrine: 1,
};

/** Taps until the box waits for the next line (each page typed out first). */
function tapThrough(session: BarVisitSession): void {
  for (let i = 0; i < 20 && session.snapshot().scene.shown !== null && !isCounterOpen(session.snapshot().scene); i++) {
    clock += 100_000;
    session.tap();
  }
}

/** A session in at her order, the bar counter open and Beer in the shaker; the first call over. */
async function atTheCounter() {
  const { ports, calls } = fakePorts();
  const session = new BarVisitSession(ports);
  session.enter("u1");
  await settle();
  const first = calls.enters[0].take();
  first.send(VISIT, line(HELLO), line(ORDER), { type: "memo", text: "她要 Beer。" }, { type: "waiting" });
  first.end();
  await settle();
  tapThrough(session);
  session.mix({ type: "bottle", drink: BEER });
  return { session, calls };
}

describe("一次光顾", () => {
  it("进门一路走到点单、开台、上酒、告别、结束卡", async () => {
    const { session, calls } = await atTheCounter();

    expect(isCounterOpen(session.snapshot().scene)).toBe(true);
    expect(mixingMemo(session.snapshot().scene)).toBe("她要 Beer。");
    expect(session.snapshot().visit).toEqual({ id: "v1", characterId: "mano" });

    session.serve();
    await settle();
    expect(calls.serves).toHaveLength(1);
    expect(calls.serves[0]).toMatchObject({ visitId: "v1", body: { method: "bottle", bottle: "beer" } });
    const reaction = calls.serves[0].take();
    await settle();
    expect(calls.sounds).toEqual(["glassserve"]);
    expect(isCounterOpen(session.snapshot().scene)).toBe(false);

    reaction.send(line(ENJOY), line(BYE), { type: "done", rewarded: { draws: 1, affinity_up: true } });
    reaction.end();
    await settle();
    expect(shownText(session.snapshot().scene, clock)?.line).toEqual(ENJOY);
    expect(calls.draws).toBe(1);
    tapThrough(session);
    expect(endCard(session.snapshot())).toEqual({ draws: true, affinityUp: true });

    session.leave();
    expect(calls.leaves).toEqual([]);
  });
});

describe("中途断了", () => {
  it("事件流没等到 waiting、failed、done 就完了，回店门口说光顾没了，离开不再发", async () => {
    const { ports, calls } = fakePorts();
    const session = new BarVisitSession(ports);
    session.enter("u1");
    await settle();
    const first = calls.enters[0].take();
    first.send(VISIT, line(HELLO));
    first.end();
    await settle();

    expect(session.snapshot()).toMatchObject({ stage: "door", notice: copy.bar.visitGone });
    session.leave();
    expect(calls.leaves).toEqual([]);
  });

  it("事件流抛错，同样回店门口", async () => {
    const { session, calls } = await atTheCounter();
    session.serve();
    await settle();
    const reaction = calls.serves[0].take();
    reaction.send(line(ENJOY));
    reaction.fail();
    await settle();

    expect(session.snapshot()).toMatchObject({ stage: "door", notice: copy.bar.visitGone });
  });
});

describe("进门被拒", () => {
  async function refusedWith(error: unknown) {
    const { ports, calls } = fakePorts();
    const session = new BarVisitSession(ports);
    session.enter("u1");
    await settle();
    calls.enters[0].refuse(error);
    await settle();
    return { session, calls };
  }

  it("酒吧关着（409）时通知一声，不写提示", async () => {
    const { session, calls } = await refusedWith(new ApiError("关着", 409));

    expect(calls.closed).toBe(1);
    expect(session.snapshot().notice).toBeNull();
  });

  it("超了限额（429）写几点以后再来", async () => {
    const at = new Date(Date.now() + 3_600_000);
    at.setSeconds(0, 0);
    const { session } = await refusedWith(new ApiError("用完了", 429, { retryAt: at.toISOString() }));

    const time = at.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });
    expect(session.snapshot()).toMatchObject({ stage: "door", notice: expect.stringContaining(time) });
  });

  it("没有 retry_at 的 429 用服务器的原话", async () => {
    const { session } = await refusedWith(new ApiError("只能用自带的密钥", 429));

    expect(session.snapshot()).toMatchObject({ stage: "door", notice: "只能用自带的密钥" });
  });

  it("其他情况一句短话，可以再点", async () => {
    const { session, calls } = await refusedWith(new Error("network"));

    expect(session.snapshot()).toMatchObject({ stage: "door", notice: copy.bar.door.failed });
    session.enter("u1");
    expect(session.snapshot().stage).toBe("entering");
    await settle();
    expect(calls.enters).toHaveLength(2);
  });
});

describe("上酒", () => {
  it("上不了的只响「不行」，什么都不发", async () => {
    const { session, calls } = await atTheCounter();
    session.mix({ type: "reset" });

    session.serve();
    await settle();

    expect(calls.sounds).toEqual(["buttonnoclick"]);
    expect(calls.serves).toEqual([]);
  });

  it("上酒期间锁着，连点两次也只发一次", async () => {
    const { session, calls } = await atTheCounter();

    session.serve();
    session.serve();
    await settle();

    expect(calls.serves).toHaveLength(1);
    expect(session.snapshot().isServing).toBe(true);
  });

  it("坏掉的（422）摇酒器显示坏了，调酒台照旧开着", async () => {
    const { session, calls } = await atTheCounter();
    session.serve();
    await settle();
    calls.serves[0].refuse(new ApiError("broken", 422));
    await settle();

    const { scene, isServing } = session.snapshot();
    expect(isServing).toBe(false);
    expect(isCounterOpen(scene)).toBe(true);
    expect(scene.mixer.garble).not.toBeNull();
    expect(calls.sounds).toEqual([]);
  });

  it("光顾没了（410）回店门口，之后离开不再发", async () => {
    const { session, calls } = await atTheCounter();
    session.serve();
    await settle();
    calls.serves[0].refuse(new ApiError("gone", 410));
    await settle();

    expect(session.snapshot()).toMatchObject({ stage: "door", notice: copy.bar.visitGone });
    session.leave();
    expect(calls.leaves).toEqual([]);
  });

  it("其他拒绝（409）一切照旧，可以再上", async () => {
    const { session, calls } = await atTheCounter();
    session.serve();
    await settle();
    calls.serves[0].refuse(new ApiError("not waiting", 409));
    await settle();

    expect(session.snapshot()).toMatchObject({ stage: "visit", isServing: false });
    expect(isCounterOpen(session.snapshot().scene)).toBe(true);
    expect(calls.closed).toBe(0);
    session.serve();
    await settle();
    expect(calls.serves).toHaveLength(2);
  });
});

describe("再试一次", () => {
  /** At the counter, served, her reaction failed. */
  async function failedReaction() {
    const at = await atTheCounter();
    at.session.serve();
    await settle();
    const reaction = at.calls.serves[0].take();
    reaction.send(line(ENJOY), line(HELLO), { type: "failed", message: "她没想好" });
    reaction.end();
    await settle();
    return at;
  }

  it("出错以后再试一次，收下了清掉这次调用的台词，接着打新来的", async () => {
    const { session, calls } = await failedReaction();
    expect(session.snapshot().failure).toBe("她没想好");

    session.retry();
    session.retry();
    expect(session.snapshot().isRetrying).toBe(true);
    await settle();
    expect(calls.retries).toHaveLength(1);
    expect(calls.retries[0].visitId).toBe("v1");
    const again = calls.retries[0].take();
    await settle();
    expect(session.snapshot()).toMatchObject({ failure: null, isRetrying: false });

    again.send(line(BYE), { type: "done", rewarded: null });
    again.end();
    await settle();
    tapThrough(session);
    expect(endCard(session.snapshot())).toEqual({ draws: false, affinityUp: false });
    expect(calls.draws).toBe(0);
  });

  it("光顾没了（410）回店门口，离开不再发", async () => {
    const { session, calls } = await failedReaction();
    session.retry();
    await settle();
    calls.retries[0].refuse(new ApiError("gone", 410));
    await settle();

    expect(session.snapshot()).toMatchObject({ stage: "door", notice: copy.bar.visitGone });
    session.leave();
    expect(calls.leaves).toEqual([]);
  });

  it("其他拒绝（409）照旧，出错还在，可以再点", async () => {
    const { session, calls } = await failedReaction();
    session.retry();
    await settle();
    calls.retries[0].refuse(new ApiError("not failed", 409));
    await settle();

    expect(session.snapshot()).toMatchObject({ stage: "visit", failure: "她没想好", isRetrying: false });
    session.retry();
    await settle();
    expect(calls.retries).toHaveLength(2);
  });
});

describe("再营业", () => {
  it("上一位那次还开着的调用被关掉，它晚到的错误不起作用", async () => {
    const { session, calls } = await atTheCounter();
    session.serve();
    await settle();
    const reaction = calls.serves[0].take();
    reaction.send(line(BYE), { type: "done", rewarded: null });
    await settle();
    tapThrough(session);
    expect(endCard(session.snapshot())).not.toBeNull();

    session.again("u1");
    expect(session.snapshot().stage).toBe("next");
    await settle();
    expect(calls.serves[0].signal.aborted).toBe(true);
    reaction.fail();
    await settle();
    expect(session.snapshot().stage).toBe("next");

    const next = calls.enters[1].take();
    next.send({ type: "visit", visit_id: "v2", character_id: "mano" }, line(HELLO));
    await settle();
    expect(session.snapshot()).toMatchObject({ stage: "visit", visit: { id: "v2" } });
  });

  it("结束卡出来之前不起作用", async () => {
    const { session, calls } = await atTheCounter();

    session.again("u1");
    await settle();

    expect(calls.enters).toHaveLength(1);
    expect(session.snapshot().stage).toBe("visit");
  });
});

describe("离开和关掉", () => {
  it("离开时关掉这次调用，离开这次光顾，回到店门口", async () => {
    const { ports, calls } = fakePorts();
    const session = new BarVisitSession(ports);
    session.enter("u1");
    await settle();
    const first = calls.enters[0].take();
    first.send(VISIT, line(HELLO));
    await settle();

    session.leave();
    await settle();

    expect(calls.enters[0].signal.aborted).toBe(true);
    expect(calls.leaves).toEqual([{ visitId: "v1", keepalive: false }]);
    expect(session.snapshot()).toMatchObject({ stage: "door", notice: null });
  });

  it("关掉（页面走开）时带 keepalive 离开，只离开一次，晚到的事件不起作用", async () => {
    const { session, calls } = await atTheCounter();
    session.serve();
    await settle();
    const reaction = calls.serves[0].take();
    await settle();
    const before = session.snapshot();

    session.close({ keepalive: true });
    session.close({ keepalive: true });
    reaction.send(line(ENJOY));
    reaction.fail();
    await settle();

    expect(calls.serves[0].signal.aborted).toBe(true);
    expect(calls.leaves).toEqual([{ visitId: "v1", keepalive: true }]);
    expect(session.snapshot()).toBe(before);
  });

  it("快照只在有变化时才换成新对象，订阅的人每次变化都听到", () => {
    const { ports } = fakePorts();
    const session = new BarVisitSession(ports);
    let heard = 0;
    const unsubscribe = session.subscribe(() => heard++);
    const door = session.snapshot();

    session.tap();
    expect(session.snapshot()).toBe(door);
    expect(heard).toBe(0);
    session.enter("u1");
    expect(session.snapshot()).not.toBe(door);
    expect(heard).toBe(1);
    unsubscribe();
  });
});
