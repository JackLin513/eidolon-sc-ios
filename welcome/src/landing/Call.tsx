"use client";

import { useEffect, useRef, useState, type CSSProperties, type PointerEvent } from "react";

import { interactionStore, useInteraction } from "./interactionStore";
import { connectTone, hangUpTone, openerShown, openerStarts, type CallPhase, type VoiceEvent } from "./model/interaction";
import { stageStore, useLayout, useStage } from "./stageStore";
import { StandSlot } from "./StandSlot";
import type { Speaker } from "./Voice";

export type CallCopy = {
  title: string;
  body: string;
  ringing: string;
  connected: string;
  ended: string;
  answer: string;
  slide: string;
  hangUp: string;
};

/** 「通话结束」在屏幕上留这么久，再回到来电。 */
const ENDED_HOLD_MS = 1500;

/**
 * 第 4 幕「来电」：她打来电话，响铃 → 接通 → 通话结束 → 响铃（model/interaction.ts）。滚动经过时只有画面在响：
 * 光跟着铃声的节奏一阵阵亮、手机振动，页面不出声。访客拖动「滑动接听」过半、点按它，或者用键盘、读屏器按下，就接通：
 * 播一声接通音，接着她说开场白（GLOSSARY「开场白」，原文和字幕，有音频时出声、立绘动嘴），开始计时；她没有开场白时
 * 只有立绘和计时。点红色挂断键是通话结束：播一声挂断音，屏幕上留一会儿「通话结束」和时长，再回到来电。声音遵守声音
 * 开关，接通音、挂断音、开场白出不出声都由交互 reducer 决定；离开这一幕就直接回到来电，不播挂断音。
 *
 * 来电在一台手机的屏幕上：屏幕（.lp-screen）摆进落地页模型给的屏幕矩形（--lp-screen-*），标题在手机上方、正文在
 * 手机下方。屏幕上是仿 iOS 的来电：来电时她的卡图作联系人海报占满屏幕（没有卡图、加载不出来时是她的印象色渐变），
 * 上面是大号的名字，底部滑动接听；接通后卡图淡出，换成她印象色的深色底，立绘从下面升上来，顶部是名字和计时，下方
 * 是开场白，底部是挂断键。
 *
 * - 运动版式：她的光收成一台手机的侧边，手机转到正面、亮屏（LightStage 和 phoneStage.ts 按落地页模型画）。three.js
 *   的画布放进 .lp-phone，和屏幕在同一个容器里一起振动（--lp-shake-x/y）；来电界面的不透明度是 --lp-act4，光脉冲是
 *   --lp-pulse。3D 手机没画出来（还在加载、建不起来、画布丢了上下文）时，屏幕下面垫的是事先渲染好的手机图。
 * - 静止版式（定格档、静态档、没有 JS）：一开始就是事先渲染好的手机图，屏幕亮着，不振动；手机和屏幕由 CSS 摆
 *   （Voice 写进 stillPhoneVars）。定格档接通后立绘静止、淡入；静态档不加载立绘，接通后卡图留着。
 */
export function Call({ speaker, copy }: { speaker: Speaker; copy: CallCopy }) {
  const { call, opener } = useInteraction();
  const { act } = useStage();
  const layout = useLayout();
  /** 静止版式：这一幕快滚到了，才挂立绘。 */
  const [near, setNear] = useState(false);
  const section = useRef<HTMLElement>(null);
  const statusEl = useRef<HTMLParagraphElement>(null);
  const clock = useCallClock(call);

  useCallAudio(speaker.opener?.audio_url ?? null);

  // 卸下时回到来电：交互状态在模块里（interactionStore），不会跟着组件重来。
  useEffect(() => () => void interactionStore.dispatch({ type: "leave-call" }), []);

  // 离开这一幕就回到来电，不播挂断音。焦点还在来电界面上的话放掉：键盘聚焦时来电界面整个看得见（landing.css），
  // 不放掉就跟着滚到别的幕上。
  const lastAct = useRef(act);
  useEffect(() => {
    const before = lastAct.current;
    lastAct.current = act;
    if (before !== 4 || act === 4) return;
    interactionStore.dispatch({ type: "leave-call" });
    const focused = document.activeElement;
    if (focused instanceof HTMLElement && section.current?.contains(focused)) focused.blur();
  }, [act]);

  // 「通话结束」留够了，回到来电。
  useEffect(() => {
    if (call !== "ended") return;
    const t = window.setTimeout(() => interactionStore.dispatch({ type: "ring" }), ENDED_HOLD_MS);
    return () => window.clearTimeout(t);
  }, [call]);

  // 静止版式：这一幕进到视口附近才挂立绘、加载卡图。
  useEffect(() => {
    if (!layout || layout.motion) return;
    const io = new IntersectionObserver(([e]) => setNear(e.isIntersecting), { rootMargin: "50% 0px" });
    io.observe(section.current!);
    return () => io.disconnect();
  }, [layout]);

  /** 接听、挂断以后按下的那个控件就不在了：焦点在来电界面上的话，交给状态那一行，不掉回页面开头。 */
  const keepFocus = () => {
    if (section.current?.contains(document.activeElement)) requestAnimationFrame(() => statusEl.current?.focus());
  };
  const answer = () => {
    const said = speaker.opener;
    keepFocus();
    interactionStore.dispatch({ type: "answer", opener: said ? (said.audio_url ? "voice" : "subtitle") : "none" });
  };
  const hangUp = () => {
    keepFocus();
    interactionStore.dispatch({ type: "hang-up" });
  };

  // 这一幕快到了（运动版式是第 3、4 幕）才挂立绘、加载卡图；卡图加载过就留着，不跟着滚动重来。静态档不挂立绘。
  const approaching = !!layout && (layout.motion ? act === 3 || act === 4 : near);
  const wantStand = !!speaker.outfit && !!layout && layout.tier !== "static" && approaching;
  const [posterWanted, setPosterWanted] = useState(false);
  useEffect(() => {
    if (approaching) setPosterWanted(true);
  }, [approaching]);
  const status = call === "connected" ? copy.connected : call === "ended" ? copy.ended : copy.ringing;

  const controls =
    call === "ringing" ? (
      <SlideToAnswer
        label={copy.answer}
        slide={copy.slide}
        onAnswer={answer}
        // 键盘聚焦到这里时来电还没显出来（没滚到，或者手机还在转）：先滚到手机停稳、亮屏的地方，滑块才在画面上。
        onFocus={() => layout?.motion && !section.current?.closest("[data-lp-call]") && stageStore.goto?.(4)}
      />
    ) : call === "connected" ? (
      <button type="button" className="lp-hang-up" onClick={hangUp} aria-label={copy.hangUp}>
        <svg viewBox="0 0 24 24" aria-hidden>
          <path d={HANDSET} transform="rotate(135 12 12)" />
        </svg>
      </button>
    ) : null;
  const said =
    call === "connected" &&
    speaker.opener &&
    openerShown(opener) && (
      <div className="lp-hello">
        <p className="lp-hello-ja" lang="ja">
          {speaker.opener.ja}
        </p>
        <p className="lp-hello-zh">{speaker.opener.subtitle}</p>
      </div>
    );
  return (
    <section ref={section} className="lp-act4" data-lp-act="4" data-phase={call} aria-labelledby="lp-act4-title">
      <div className="lp-call-glow" aria-hidden />
      <div className="lp-act4-copy" data-lp-find="act4">
        <h2 id="lp-act4-title" className="lp-act-title">
          {copy.title}
        </h2>
        <p className="lp-act-body">{copy.body}</p>
      </div>
      <div className="lp-phone">
        {/* 事先渲染好的手机（scripts/landing-phone-still.mjs）：静止版式里一直在；运动版式里 3D 手机没画出来时才显示，
            平时 display: none，懒加载的图不下载（landing.css）。 */}
        <img className="lp-phone-img" src={PHONE_STILL} alt="" loading="lazy" decoding="async" aria-hidden />
        <div className="lp-screen">
          <div className="lp-screen-poster" aria-hidden>
            {posterWanted && speaker.poster && <Poster src={speaker.poster} />}
          </div>
          <div className="lp-screen-wall" aria-hidden />
          {wantStand && (
            <div className="lp-screen-stand" aria-hidden>
              <StandSlot
                outfit={speaker.outfit!}
                framing="waist"
                still={!layout.motion}
                speaking={opener?.voice === "playing"}
                paused={call !== "connected"}
              />
            </div>
          )}
          <div className="lp-call-ui">
            <div className="lp-call-head">
              <p className="lp-call-name" lang="ja" data-lp-find="act4">
                {speaker.name}
              </p>
              <p ref={statusEl} className="lp-call-status" role="status" tabIndex={-1}>
                {status}
                {call === "connected" && clock.since !== null && <Elapsed since={clock.since} />}
                {call === "ended" && clock.lasted !== null && <Duration ms={clock.lasted} />}
              </p>
            </div>
            <div className="lp-call-foot">
              {said}
              {controls}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

/** 事先渲染好的正面、熄屏的手机图（public/landing/phone/）。 */
const PHONE_STILL = "/landing/phone/still.webp";

/** 卡图：加载出来以后才盖住印象色的后备海报；加载不出来就一直是后备海报。 */
function Poster({ src }: { src: string }) {
  const [state, setState] = useState<"loading" | "shown" | "failed">("loading");
  if (state === "failed") return null;
  return (
    // 不用 next/image：它不进落地页的包，卡图在存储桶上已经裁好、压好了。
    <img
      className="lp-poster"
      src={src}
      alt=""
      decoding="async"
      data-shown={state === "shown" || undefined}
      onLoad={() => setState("shown")}
      onError={() => setState("failed")}
    />
  );
}

/** 听筒的图形：接听键上竖着，挂断键上转 135°。 */
const HANDSET =
  "M6.6 10.8a15.2 15.2 0 0 0 6.6 6.6l2.2-2.2a1 1 0 0 1 1-.25 11.4 11.4 0 0 0 3.6.57 1 1 0 0 1 1 1V20a1 1 0 0 1-1 1A17 17 0 0 1 3 4a1 1 0 0 1 1-1h3.5a1 1 0 0 1 1 1c0 1.25.2 2.45.57 3.57a1 1 0 0 1-.25 1z";

/** 拖动超过这么多像素就不算点按。 */
const DRAG_SLOP = 6;
/** 拖完松手以后这么久之内的 click 是浏览器补的那一下，不算点按。触屏上拖远了浏览器多半不补，不能等它来清掉。 */
const CLICK_AFTER_DRAG_MS = 400;

/**
 * 「滑动接听」：读屏器眼里是一个名为「接听」的按钮。把圆钮往右拖过一半、松手就接听；点按、回车、空格也直接接听。
 * 只吃横向手势（touch-action: pan-y）：手指竖着划，浏览器拿去滚动页面，指针事件被取消，不会误接。
 *
 * 在松手（pointerup）时接听而不是拖动中途：手机浏览器只认按下、松手这类手势里发起的播放，接通音要在这里放。
 */
function SlideToAnswer({
  label,
  slide,
  onAnswer,
  onFocus,
}: {
  label: string;
  slide: string;
  onAnswer: () => void;
  onFocus: () => void;
}) {
  const track = useRef<HTMLButtonElement>(null);
  const knob = useRef<HTMLSpanElement>(null);
  const drag = useRef<{ id: number; x: number; max: number; dx: number; moved: boolean } | null>(null);
  /** 上一次拖完松手的时刻（performance.now()）。 */
  const droppedAt = useRef(-Infinity);
  const [dx, setDx] = useState<number | null>(null);

  const down = (e: PointerEvent<HTMLButtonElement>) => {
    if (e.button !== 0 || !track.current || !knob.current) return;
    const max = track.current.clientWidth - knob.current.offsetWidth - 2 * knob.current.offsetLeft;
    drag.current = { id: e.pointerId, x: e.clientX, max, dx: 0, moved: false };
  };
  const move = (e: PointerEvent<HTMLButtonElement>) => {
    const d = drag.current;
    if (!d || d.id !== e.pointerId) return;
    d.dx = Math.min(d.max, Math.max(0, e.clientX - d.x));
    if (!d.moved && Math.abs(e.clientX - d.x) > DRAG_SLOP) {
      d.moved = true;
      e.currentTarget.setPointerCapture(e.pointerId);
    }
    if (d.moved) setDx(d.dx);
  };
  const up = (e: PointerEvent<HTMLButtonElement>) => {
    const d = drag.current;
    if (!d || d.id !== e.pointerId) return;
    drag.current = null;
    setDx(null);
    if (!d.moved) return;
    droppedAt.current = performance.now();
    if (d.dx > d.max / 2) onAnswer();
  };
  const cancel = () => {
    drag.current = null;
    setDx(null);
  };

  return (
    <button
      ref={track}
      type="button"
      className="lp-slide"
      aria-label={label}
      data-dragging={dx !== null || undefined}
      onPointerDown={down}
      onPointerMove={move}
      onPointerUp={up}
      onPointerCancel={cancel}
      onClick={() => {
        if (performance.now() - droppedAt.current > CLICK_AFTER_DRAG_MS) onAnswer();
      }}
      onFocus={onFocus}
      style={dx === null ? undefined : ({ "--lp-slide-x": `${dx}px` } as CSSProperties)}
    >
      <span ref={knob} className="lp-slide-knob" aria-hidden>
        <svg viewBox="0 0 24 24">
          <path d={HANDSET} />
        </svg>
      </span>
      <span className="lp-slide-label" aria-hidden>
        {slide}
      </span>
    </button>
  );
}

/** 这一通电话的时刻（performance.now()）：接通的时刻，挂断时打了多久。来电时都是 null。 */
function useCallClock(call: CallPhase): { since: number | null; lasted: number | null } {
  const [clock, setClock] = useState<{ since: number | null; lasted: number | null }>({ since: null, lasted: null });
  useEffect(() => {
    setClock((c) => {
      if (call === "connected") return { since: performance.now(), lasted: null };
      if (call === "ended") return { since: null, lasted: c.since === null ? null : performance.now() - c.since };
      return { since: null, lasted: null };
    });
  }, [call]);
  return clock;
}

const mmss = (ms: number) => {
  const s = Math.floor(ms / 1000);
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
};

/** 通话时长，一秒一跳。读屏器不念它（状态那一行只在状态变化时念）。 */
function Elapsed({ since }: { since: number }) {
  const [now, setNow] = useState(since);
  useEffect(() => {
    const t = window.setInterval(() => setNow(performance.now()), 1000);
    return () => window.clearInterval(t);
  }, []);
  return (
    <span className="lp-call-time" aria-hidden>
      {mmss(now - since)}
    </span>
  );
}

/** 挂断时这通电话打了多久。 */
function Duration({ ms }: { ms: number }) {
  return (
    <span className="lp-call-time" aria-hidden>
      {mmss(ms)}
    </span>
  );
}

const CONNECT_TONE = "/sounds/connect.ogg";
const HANG_UP_TONE = "/sounds/hang-up.mp3";
/** 开场白这么久还没开始播就当作加载失败，退成只有字幕（和招呼一样）。 */
const OPENER_LOAD_TIMEOUT_MS = 8000;

/** 接通音、挂断音和开场白的那个 <audio> 现在放的是哪一样。 */
type Playing = { what: "tone" } | { what: "opener"; n: number; timeout: number };

/**
 * 接通音、挂断音和开场白：两样提示音复用应用通话用的文件（GLOSSARY「接通音」「挂断音」），接通、挂断时各播一次
 * （model/interaction.ts 的 connectTone、hangUpTone）；接通音放完（或放不出来），reducer 说轮到她开口
 * （openerStarts），就放开场白 `openerUrl`。
 *
 * 几样用同一个 <audio>，第一次接通时才建：订阅者在 dispatch 里同步跑，接通音在访客接听的手势里放，同一个元素之后
 * 换成开场白、挂断音再放，手机浏览器不会拦。开始播、播完、放不出来都报给 reducer（第一次出声时出现声音开关），放不
 * 出来不当作错误。挂断、离开这一幕、关掉声音开关时 reducer 不再要开场白的声音，这里就停下。
 */
function useCallAudio(openerUrl: string | null) {
  const url = useRef(openerUrl);
  useEffect(() => {
    url.current = openerUrl;
  }, [openerUrl]);

  useEffect(() => {
    const dispatch = interactionStore.dispatch;
    let el: HTMLAudioElement | null = null;
    let now: Playing | null = null;

    /** 正在放的那样报一个事件；早就换掉了的（例如接通音被开场白顶掉时它的 play() 被打断）不报。 */
    const report = (playing: Playing | null, event: VoiceEvent) => {
      if (!playing || playing !== now) return;
      if (playing.what === "tone") return dispatch({ type: "tone", event });
      if (event !== "playing") now = null;
      window.clearTimeout(playing.timeout);
      dispatch({ type: "opener", n: playing.n, event });
    };
    const audio = () => {
      if (el) return el;
      el = new Audio();
      el.addEventListener("playing", () => report(now, "playing"));
      el.addEventListener("ended", () => report(now, "ended"));
      el.addEventListener("error", () => report(now, "failed"));
      return el;
    };
    const play = (playing: Playing, src: string) => {
      const a = audio();
      if (now?.what === "opener") window.clearTimeout(now.timeout);
      now = playing;
      a.src = src;
      a.currentTime = 0;
      a.play().catch(() => report(playing, "failed"));
    };
    const stop = () => {
      if (now?.what === "opener") window.clearTimeout(now.timeout);
      now = null;
      el?.pause();
    };

    const unsubscribe = interactionStore.subscribe((prev, next) => {
      if (connectTone(prev, next)) play({ what: "tone" }, CONNECT_TONE);
      // 挂断音顶掉正在说的开场白。
      if (hangUpTone(prev, next)) return play({ what: "tone" }, HANG_UP_TONE);
      const n = openerStarts(prev, next);
      if (n !== null) {
        // 没有地址（不该发生：没有音频时接听就只有字幕）也退成字幕；不在订阅者里同步再 dispatch。
        if (!url.current) return queueMicrotask(() => dispatch({ type: "opener", n, event: "failed" }));
        const playing: Playing = { what: "opener", n, timeout: 0 };
        playing.timeout = window.setTimeout(() => report(playing, "failed"), OPENER_LOAD_TIMEOUT_MS);
        play(playing, url.current);
        return;
      }
      // 离开这一幕了、关掉了声音开关：她不再出声。提示音照常放完。
      const voicing = (v: typeof next.opener) => v?.voice === "loading" || v?.voice === "playing";
      if (now?.what === "opener" && voicing(prev.opener) && !voicing(next.opener)) stop();
    });
    return () => {
      unsubscribe();
      stop();
    };
  }, []);
}
