"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import { createPortal } from "react-dom";

import type { Greeting, Outfit } from "@/lib/api";

import { interactionStore, useInteraction } from "./interactionStore";
import { focusOf, holdMs, voicing, type InteractionAction, type Saying, type VoiceEvent } from "./model/interaction";
import { stageStore, useLayout, useStage } from "./stageStore";
import { StandSlot } from "./StandSlot";

/** 一块名牌：名字、编号、颜色都由服务端算好。 */
export type Plate = {
  id: string;
  name: string;
  /** 偶像编号，两位数补零；没有编号时为 null。 */
  number: string | null;
  /** 她在第几个组合、组合里第几位、组合有几人：LightStage 按它把名牌摆到横滚轨道上。 */
  unit: number;
  slot: number;
  unitSize: number;
  /** 黑底和她的极深底色上写名字的颜色、光晕色、官方色、极深底色（color.ts）。 */
  ink: string;
  halo: string;
  official: string;
  deep: string;
  /** 她的默认衣装；没配立绘素材时为 null，聚焦时只有名字和光。 */
  outfit: Outfit | null;
  /** 她的招呼；没有招呼时为 null，点了只聚焦。没有音频地址时只显示字幕。 */
  greeting: Greeting | null;
};

export type SpectrumUnit = {
  /** 组合名；查不到组合的偶像排在最后一段，这一段没有组合名。 */
  name: string | null;
  plates: Plate[];
};

export type SpectrumCopy = {
  label: string;
  jump: string;
  jumpTo: string[];
  others: string;
  /** 声音开关：按钮名和开、关两种状态。 */
  sound: string;
  soundOn: string;
  soundOff: string;
};

/** 聚焦停留这么久才挂立绘：鼠标扫过几块名牌时不接连加载。 */
const STAND_DELAY_MS = 220;
/** 离开她这么久才卸下立绘，淡出有时间走完。 */
const STAND_RELEASE_MS = 450;


/**
 * 第 2 幕「光谱」：全部偶像的竖排日文名，按组合分段，名字和组合名都是真文本，服务端渲染。
 *
 * - 运动版式：名牌由 LightStage 摆到横滚轨道上（轨道每个组合一屏），光由着色器画；底部常驻当前组合名，
 *   可以按组合跳转。聚焦（指针移上去、键盘聚焦、手指点）时她的立绘从光里浮现：立绘压在其他人的
 *   名牌上面，只有她自己的名牌在立绘之上（原型里用户专门纠正过）。竖屏例外：立绘宽，和她的名牌叠着，
 *   名字会盖在脸上，立绘也压在她的名牌上面（用户验收时定的）。
 * - 静止版式（定格档、静态档、没有 JS）：组合一段一段竖着排，光由 CSS 画。定格档聚焦时立绘只画一帧，
 *   静态档（不支持 WebGL）没有立绘。
 *
 * 聚焦写进 stageStore，循环据此让背景过渡到她的极深底色、其余的人降成余烬；该不该挂立绘由落地页模型
 * 判断（光谱停稳、她在当前组合里），经 stageStore 传回来。推入下一个组合时放下聚焦。
 *
 * 点一位偶像（或者聚焦后按 Enter）听她的招呼，配日语原文和中文字幕；第一次出声以后右上角出现常驻的
 * 声音开关，关掉以后只显示字幕。聚焦、点击、要不要出声都由交互 reducer（model/interaction.ts）决定，
 * 这里只负责放声音、计字幕的时。没有招呼的偶像点了只聚焦。
 */
export function Spectrum({ units, copy }: { units: SpectrumUnit[]; copy: SpectrumCopy }) {
  const state = useInteraction();
  const dispatch = interactionStore.dispatch;
  const layout = useLayout();
  /** 右上角入口所在的页头（Landing 渲染的 .lp-top）：声音开关放进去，和入口排在一起。 */
  const [header, setHeader] = useState<HTMLElement | null>(null);
  const { act, unit, stand } = useStage();
  const plates = units.flatMap((u) => u.plates);
  const focus = focusOf(state);
  const focusedPlate = plates.find((p) => p.id === focus) ?? null;
  const saying = state.saying;
  const sayingPlate = saying && plates.find((p) => p.id === saying.id);

  useEffect(() => setHeader(document.querySelector<HTMLElement>(".lp-top")), []);

  // 聚焦交给舞台的循环：它据此让她的光和背景淡入。
  useEffect(() => {
    stageStore.focus = focus;
  }, [focus]);

  // 推入下一个组合时放下聚焦，立绘和字幕不跟着跑到别的组合里；离开光谱这一幕时也放下，正在说的收掉。
  const last = useRef({ act, unit });
  useEffect(() => {
    const before = last.current;
    last.current = { act, unit };
    if (before.act === 2 && act !== 2) dispatch({ type: "leave" });
    else if (unit !== before.unit && focus && plates.find((p) => p.id === focus)?.unit !== unit) dispatch({ type: "leave" });
  });

  const voice = useVoice(state.saying, dispatch);
  const press = (plate: Plate) => {
    const action: InteractionAction = {
      type: "press",
      id: plate.id,
      greeting: plate.greeting ? (plate.greeting.audio_url ? "voice" : "subtitle") : "none",
    };
    // 在点击的处理函数里就开始播：手机浏览器只认用户手势里发起的播放。
    const next = dispatch(action).saying;
    if (next?.voice === "loading" && plate.greeting?.audio_url) voice.play(next.n, plate.greeting.audio_url);
  };

  // 字幕留够了就收掉：声音还在加载或在播时等它。
  useEffect(() => {
    if (!saying) return;
    const ms = holdMs(saying);
    if (ms === null) return;
    const t = window.setTimeout(() => dispatch({ type: "done", n: saying.n }), ms);
    return () => window.clearTimeout(t);
  }, [saying]);

  // 运动版式：立绘跟着落地页模型（停稳了才有）；静止版式：聚焦到谁就是谁。
  const wanted = layout?.motion ? stand : layout?.tier === "reduced" ? focus : null;
  const standFor = useDelayed(wanted);
  const standPlate = plates.find((p) => p.id === standFor && p.outfit);
  const speaking = (id: string) => saying?.id === id && saying.voice === "playing";

  const standSlot = (plate: Plate) => (
    <div
      className="lp-stand"
      data-shown={wanted === plate.id ? "" : undefined}
      data-side={plate.slot < plate.unitSize / 2 ? "after" : "before"}
      aria-hidden
    >
      <StandSlot key={plate.id} outfit={plate.outfit!} still={!layout?.motion} speaking={speaking(plate.id)} />
    </div>
  );

  return (
    <section
      className="lp-act2"
      data-lp-act="2"
      aria-label={copy.label}
      data-focus={focus ?? undefined}
      style={focusedPlate ? ({ "--her-deep": focusedPlate.deep } as CSSProperties) : undefined}
    >
      <div className="lp-track">
        {units.map((u, i) => (
          <section
            key={u.name ?? ""}
            id={`lp-unit-${i}`}
            className="lp-seg"
            aria-labelledby={`lp-unit-name-${i}`}
            style={{ "--u": i } as CSSProperties}
            data-focused={focusedPlate && focusedPlate.unit === i ? "" : undefined}
          >
            <h2 id={`lp-unit-name-${i}`} className="lp-seg-name" lang={u.name ? "ja" : undefined}>
              {u.name ?? copy.others}
            </h2>
            <ol className="lp-seg-row">
              {u.plates.map((plate) => (
                <li key={plate.id} className="lp-plate-slot">
                  <button
                    type="button"
                    className="lp-plate"
                    data-lp-id={plate.id}
                    data-focused={focus === plate.id ? "" : undefined}
                    style={{ "--her-ink": plate.ink, "--her-halo": plate.halo } as CSSProperties}
                    onPointerEnter={(e) => e.pointerType === "mouse" && dispatch({ type: "point", id: plate.id })}
                    onPointerLeave={(e) => e.pointerType === "mouse" && dispatch({ type: "unpoint", id: plate.id })}
                    onFocus={() => {
                      dispatch({ type: "point", id: plate.id });
                      // 键盘聚焦到别的组合（或者还没滚到光谱）里的名牌：滚过去，名牌才在画面上。
                      const at = stageStore.get();
                      if (layout?.motion && (at.act !== 2 || plate.unit !== at.unit)) stageStore.jump?.(plate.unit, true);
                    }}
                    onBlur={() => dispatch({ type: "unpoint", id: plate.id })}
                    onClick={() => press(plate)}
                  >
                    <span className="lp-plate-body">
                      {plate.number && (
                        <span className="lp-no" aria-hidden>
                          {plate.number}
                        </span>
                      )}
                      <span className="lp-name" lang="ja">
                        {plate.name}
                      </span>
                      <span className="lp-hex" aria-hidden>
                        {plate.official.toUpperCase()}
                      </span>
                    </span>
                  </button>
                  {/* 静止版式：立绘在名牌旁边，压在同一段里其他人的名牌上。 */}
                  {!layout?.motion && standPlate?.id === plate.id && standSlot(plate)}
                </li>
              ))}
            </ol>
          </section>
        ))}
        {/* 运动版式：立绘在轨道里，跟着轨道走；LightStage 把它摆到她名牌旁边空间大的一边。 */}
        {layout?.motion && (
          <div className="lp-stand" data-lp-stand={standFor ?? undefined} data-shown={stand && stand === standFor ? "" : undefined} aria-hidden>
            {standPlate && <StandSlot key={standPlate.id} outfit={standPlate.outfit!} still={false} speaking={speaking(standPlate.id)} />}
          </div>
        )}
        {/* 招呼的字幕：日语原文和中文字幕都是真文本，读屏器会念出来。运动版式里 LightStage 把它摆到立绘那里，
            静止版式里贴在视口底部。框一直在，读屏器才会念出新放进去的字。 */}
        <div className="lp-greeting" role="status" data-lp-greeting={sayingPlate?.greeting ? sayingPlate.id : undefined}>
          {sayingPlate?.greeting && (
            <div key={saying!.n} className="lp-greeting-line" style={{ "--her-ink": sayingPlate.ink } as CSSProperties}>
              <p className="lp-greeting-ja" lang="ja">
                {sayingPlate.greeting.ja}
              </p>
              <p className="lp-greeting-zh">{sayingPlate.greeting.subtitle}</p>
            </div>
          )}
        </div>
      </div>

      {header &&
        state.sound !== "hidden" &&
        createPortal(
          <button type="button" className="lp-sound" aria-pressed={state.sound === "on"} onClick={() => dispatch({ type: "sound" })}>
            {copy.sound}
            <span aria-hidden> {state.sound === "on" ? copy.soundOn : copy.soundOff}</span>
          </button>,
          header,
        )}

      {layout?.motion && units.length > 1 && (
        <nav
          className="lp-unitbar"
          aria-label={copy.jump}
          // 从后面的幕用 Shift+Tab 退回到跳转按钮：先滚回光谱，按钮才在画面上。
          onFocus={() => stageStore.get().act !== 2 && stageStore.jump?.(stageStore.get().unit, true)}
        >
          <span className="lp-unitbar-name" lang="ja" aria-hidden>
            {units[unit]?.name ?? copy.others}
          </span>
          <ol className="lp-unitjump">
            {units.map((u, i) => (
              <li key={u.name ?? ""}>
                <button
                  type="button"
                  aria-label={copy.jumpTo[i]}
                  aria-current={i === unit ? "true" : undefined}
                  title={u.name ?? copy.others}
                  onClick={() => stageStore.jump?.(i)}
                >
                  {String(i + 1).padStart(2, "0")}
                </button>
              </li>
            ))}
          </ol>
        </nav>
      )}
    </section>
  );
}

/** 音频这么久还没开始播就当作加载失败：存储桶不回应、请求一直挂着时，字幕照常按只有字幕的时长收掉。 */
const VOICE_LOAD_TIMEOUT_MS = 8000;

/**
 * 招呼的声音：点了才加载（`play`），同时只有一句。开始播、播完、加载或播放失败都报给 reducer；
 * 失败（存储桶下线、文件不在、迟迟加载不出来）时只剩字幕，不报错。正在说的那句停了（换了一句、
 * 开关关掉、收掉），这里就把它停下。
 */
function useVoice(saying: Saying | null, dispatch: (a: InteractionAction) => void) {
  const current = useRef<{ n: number; audio: HTMLAudioElement; timeout: number } | null>(null);
  const stop = () => {
    const v = current.current;
    if (!v) return;
    current.current = null;
    window.clearTimeout(v.timeout);
    v.audio.pause();
    v.audio.removeAttribute("src");
    v.audio.load();
  };

  const live = voicing(saying) ? saying!.n : null;
  useEffect(() => {
    if (current.current && current.current.n !== live) stop();
  }, [live]);
  useEffect(() => stop, []);

  return {
    play(n: number, url: string) {
      stop();
      const audio = new Audio(url);
      const report = (event: VoiceEvent) => () => dispatch({ type: "voice", n, event });
      const timeout = window.setTimeout(report("failed"), VOICE_LOAD_TIMEOUT_MS);
      audio.addEventListener("playing", () => {
        window.clearTimeout(timeout);
        report("playing")();
      });
      audio.addEventListener("ended", report("ended"));
      audio.addEventListener("error", report("failed"));
      current.current = { n, audio, timeout };
      audio.play().catch(report("failed"));
    },
  };
}

/** 要挂立绘的人：停留一会儿才换上，离开一会儿才卸下。 */
function useDelayed(wanted: string | null): string | null {
  const [current, setCurrent] = useState<string | null>(null);
  useEffect(() => {
    if (wanted === current) return;
    const t = window.setTimeout(() => setCurrent(wanted), wanted ? STAND_DELAY_MS : STAND_RELEASE_MS);
    return () => window.clearTimeout(t);
  }, [wanted, current]);
  return current;
}
