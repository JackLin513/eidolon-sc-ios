// 落地页的交互状态（spec「交互状态」）：聚焦和点击偶像，招呼要不要出声，声音开关，第 4 幕的接听。
// 纯函数，不碰 DOM：音频的加载、播放和字幕的计时由组件做，结果以动作报回来。
//
// - 聚焦本身从不出声，页面也从不自动出声：只有点了偶像、接听了电话才有声音。
// - 第一次点就出声；真的出了声，才出现常驻的声音开关（开着），音频加载不出来时不出现一个管不了什么的开关。
//   关掉以后点偶像只显示字幕，接听也不出声。
// - 同时只说一句：点另一位、或者指针移到另一位身上，上一句就停下；接听时招呼也停下。
// - 第 4 幕的来电：响铃 → 接通 → 通话结束 → 响铃。滚动经过时只有画面在响。访客接听就接通，播一声接通音
//   （GLOSSARY「接通音」），不放铃声；点挂断键就是通话结束，播一声挂断音（GLOSSARY「挂断音」），留一会儿再回到
//   响铃，可以再接一次。离开这一幕不论接通还是通话结束，都直接回到响铃，不播挂断音。
// - 接通音响完，打来电话的那位说开场白（GLOSSARY「开场白」）：声音开关没关、有音频时出声，字幕和声音一起出来；
//   否则一接通就只有字幕。放不出来退成只有字幕，不当错误；真的出了声，和招呼一样让声音开关出现。挂断就停下。

/** 正在说的一句。`n` 每说一句加一：音频事件和字幕的计时都带着它，上一句的事件不会落到这一句上。 */
export type Saying = {
  id: string;
  n: number;
  /** 声音：`loading` 加载中、`playing` 在播、`ended` 播完了；null 是只有字幕（没有音频、开关关着、加载失败）。 */
  voice: "loading" | "playing" | "ended" | null;
};

/** 第 4 幕的来电：`ringing` 在响（只有画面），`connected` 接通了，`ended` 挂断了、屏幕上是「通话结束」。 */
export type CallPhase = "ringing" | "connected" | "ended";

/** 这一通电话的开场白。`n` 是第几通：音频事件带着它，上一通的事件不会落到这一通上。 */
export type Opener = {
  n: number;
  /** 声音：`waiting` 等接通音响完、`loading` 加载中、`playing` 在播、`ended` 播完了；null 是只有字幕。 */
  voice: "waiting" | "loading" | "playing" | "ended" | null;
};

export type Interaction = {
  /** 指针、键盘焦点、手指指着的那位。 */
  pointed: string | null;
  /** 声音开关：第一次真的出声之前不出现；不出现时当作开着。 */
  sound: "hidden" | "on" | "off";
  saying: Saying | null;
  /** 说过几句，给下一句编号。 */
  said: number;
  call: CallPhase;
  /** 接通以后她的开场白；没接通、或者她没有开场白时是 null。 */
  opener: Opener | null;
  /** 接通过几次，给下一通编号。 */
  calls: number;
};

export const INITIAL: Interaction = {
  pointed: null,
  sound: "hidden",
  saying: null,
  said: 0,
  call: "ringing",
  opener: null,
  calls: 0,
};

export type VoiceEvent = "playing" | "ended" | "failed";

export type InteractionAction =
  /** 指针移上去、键盘聚焦。 */
  | { type: "point"; id: string }
  /** 指针移开、键盘焦点离开。 */
  | { type: "unpoint"; id: string }
  /** 点了她（或者聚焦后按 Enter）。`greeting`：她没有招呼、只有字幕（没有音频地址）、有音频。 */
  | { type: "press"; id: string; greeting: "none" | "subtitle" | "voice" }
  /** 离开她所在的地方（推入别的组合）：放下聚焦，正在说的也收掉。 */
  | { type: "leave" }
  /** 点声音开关。 */
  | { type: "sound" }
  /** 第 n 句的音频开始播放、播完、加载或播放失败（包括迟迟加载不出来）。 */
  | { type: "voice"; n: number; event: VoiceEvent }
  /** 第 n 句的字幕留够了。 */
  | { type: "done"; n: number }
  /** 接听了（拖过一半、点按，或用键盘、读屏器按下）。`opener`：打来电话的那位没有开场白、只有字幕（没有音频地址）、有音频。 */
  | { type: "answer"; opener: "none" | "subtitle" | "voice" }
  /** 点了挂断键。 */
  | { type: "hang-up" }
  /** 「通话结束」留够了：回到响铃。 */
  | { type: "ring" }
  /** 离开第 4 幕：不论在哪一步，都回到响铃的样子。 */
  | { type: "leave-call" }
  /** 接通音、挂断音真的响起来了、放完了，或者放不出来。 */
  | { type: "tone"; event: "playing" | "ended" | "failed" }
  /** 第 n 通电话的开场白开始播放、播完、加载或播放失败（包括迟迟加载不出来）。 */
  | { type: "opener"; n: number; event: VoiceEvent };

/** 聚焦的那位：指着谁就是谁；谁都没指着时，正在说话的她。 */
export const focusOf = (s: Interaction): string | null => s.pointed ?? s.saying?.id ?? null;

/** 只有字幕时留这么久（毫秒），够读完一句日语和它的字幕。 */
const TEXT_HOLD_MS = 7000;
/** 声音播完以后字幕再留这么久。 */
const AFTER_VOICE_MS = 1800;

/** 声音还在路上：在加载或在播。 */
export const voicing = (saying: Saying | null): boolean => saying?.voice === "loading" || saying?.voice === "playing";

/** 字幕还要留多久；音频还在加载或在播时等它（null）。 */
export function holdMs(saying: Saying): number | null {
  if (voicing(saying)) return null;
  return saying.voice === "ended" ? AFTER_VOICE_MS : TEXT_HOLD_MS;
}

export function interactionReducer(s: Interaction, a: InteractionAction): Interaction {
  switch (a.type) {
    case "point":
      return { ...s, pointed: a.id, saying: s.saying?.id === a.id ? s.saying : null };
    case "unpoint":
      return s.pointed === a.id ? { ...s, pointed: null } : s;
    case "press": {
      if (a.greeting === "none") return { ...s, pointed: a.id, saying: null };
      const voiced = a.greeting === "voice" && s.sound !== "off";
      const n = s.said + 1;
      return {
        ...s,
        pointed: a.id,
        saying: { id: a.id, n, voice: voiced ? "loading" : null },
        said: n,
      };
    }
    case "leave":
      return { ...s, pointed: null, saying: null };
    case "sound":
      if (s.sound === "hidden") return s;
      if (s.sound === "off") return { ...s, sound: "on" };
      return { ...s, sound: "off", saying: s.saying && { ...s.saying, voice: null }, opener: s.opener && { ...s.opener, voice: null } };
    case "voice": {
      if (s.saying?.n !== a.n || s.saying.voice === null) return s;
      const voice = a.event === "failed" ? null : a.event;
      return { ...s, saying: { ...s.saying, voice }, sound: voice === "playing" && s.sound === "hidden" ? "on" : s.sound };
    }
    case "done":
      return s.saying?.n === a.n ? { ...s, saying: null } : s;
    case "answer": {
      if (s.call !== "ringing") return s;
      const n = s.calls + 1;
      const voiced = a.opener === "voice" && s.sound !== "off";
      const opener: Opener | null = a.opener === "none" ? null : { n, voice: voiced ? "waiting" : null };
      return { ...s, saying: null, call: "connected", opener, calls: n };
    }
    case "hang-up":
      return s.call === "connected" ? { ...s, call: "ended", opener: null } : s;
    case "ring":
      return s.call === "ended" ? { ...s, call: "ringing" } : s;
    case "leave-call":
      return s.call === "ringing" ? s : { ...s, call: "ringing", opener: null };
    case "tone":
      if (a.event === "playing") return s.sound === "hidden" ? { ...s, sound: "on" } : s;
      // 接通音放完了（或者放不出来）：轮到她开口。
      return s.opener?.voice === "waiting" ? { ...s, opener: { ...s.opener, voice: "loading" } } : s;
    case "opener": {
      if (s.opener?.n !== a.n || s.opener.voice === null) return s;
      const voice = a.event === "failed" ? null : a.event;
      return { ...s, opener: { ...s.opener, voice }, sound: voice === "playing" && s.sound === "hidden" ? "on" : s.sound };
    }
  }
}

/** 状态从 `prev` 变成 `next` 时要不要开始放开场白：接通音刚放完（或放不出来），轮到她开口。要放的话给出是第几通。 */
export const openerStarts = (prev: Interaction, next: Interaction): number | null =>
  next.opener?.voice === "loading" && prev.opener?.voice !== "loading" ? next.opener.n : null;

/** 开场白的原文和字幕要不要显示：她开口了、说完了，或者只有字幕；还在等接通音、在加载时不显示。 */
export const openerShown = (opener: Opener | null): boolean =>
  !!opener && opener.voice !== "waiting" && opener.voice !== "loading";

/** 状态从 `prev` 变成 `next` 时要不要播接通音：刚接通，并且声音开关没关。 */
export const connectTone = (prev: Interaction, next: Interaction): boolean =>
  prev.call === "ringing" && next.call === "connected" && next.sound !== "off";

/** 状态从 `prev` 变成 `next` 时要不要播挂断音：点了挂断键，并且声音开关没关。离开这一幕不播。 */
export const hangUpTone = (prev: Interaction, next: Interaction): boolean =>
  prev.call === "connected" && next.call === "ended" && next.sound !== "off";
