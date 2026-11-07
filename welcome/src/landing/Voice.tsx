import type { CSSProperties } from "react";

import type { CallOpener } from "@/lib/api";

import { Call, type CallCopy } from "./Call";
import { stillPhoneVars } from "./model/phone";
import type { Section } from "./model/timeline";
import type { Plate } from "./Spectrum";

/** 说话、打来电话的那一位：她在光谱里的名牌的那几样（名字、颜色、默认衣装），接通后她说的开场白（GLOSSARY
 * 「开场白」）和来电时的卡图（存储桶上的地址），都由服务端算好。没配立绘素材时没有衣装，来电时只有名字和光；没有
 * 开场白时接通后只有立绘和计时；没有卡图时来电画面是她的印象色。 */
export type Speaker = Pick<Plate, "name" | "ink" | "halo" | "deep" | "outfit"> & { opener: CallOpener | null; poster: string | null };

export type TalkCopy = { title: string; body: string; lines: readonly { ja: string; zh: string }[] };

/**
 * 第 3 幕「她说日语」和第 4 幕「来电」，钉在同一个舞台上：她那一道光从说话一路变成来电。
 *
 * 第 3 幕服务端渲染，不带客户端 JS：她说的几句日语竖排成一列一列，中文字幕在底下。运动版式里 LightStage
 * 按落地页模型写进每一句的进度（--lp-ja-k 原文这一列的不透明度、--lp-sweep-k 字幕被光扫到哪儿、--lp-sub-k
 * 字幕的不透明度），字幕被一道亮边从左往右扫出来，同一时刻只看得到一句；她的光由着色器画。静止版式（定格档、
 * 静态档、没有 JS）里原文和几句字幕都完整显示，光由 CSS 画。
 *
 * 第 4 幕见 Call。两幕的文字跟着模型淡入淡出（--lp-act3、--lp-act4）。静止版式里第 4 幕的手机由 CSS 摆，摆法的
 * 几个量（model/phone.ts 的 stillPhoneVars）在这里写进内联样式，落地页模型不进客户端的包。
 */
export function Voice({
  section,
  speaker,
  talk,
  call,
}: {
  section: Section;
  speaker: Speaker;
  talk: TalkCopy;
  call: CallCopy;
}) {
  const vars = {
    "--lp-screens": section.screens,
    "--her-ink": speaker.ink,
    "--her-halo": speaker.halo,
    "--her-deep": speaker.deep,
    ...stillPhoneVars(),
  };
  return (
    <div className="lp-stage-wrap lp-voice" data-lp-section={section.index} style={vars as CSSProperties}>
      <div className="lp-stage">
        <section className="lp-act3" data-lp-act="3" aria-labelledby="lp-act3-title">
          <div className="lp-talk-light" aria-hidden />
          <div className="lp-act3-copy" data-lp-find="act3">
            <h2 id="lp-act3-title" className="lp-act-title">
              {talk.title}
            </h2>
            <p className="lp-act-body">{talk.body}</p>
          </div>
          <div className="lp-talk" lang="ja">
            {talk.lines.map((line, k) => (
              <p key={k} className="lp-talk-col" data-lp-find={`ja-${k}`} style={{ "--lp-o": `var(--lp-ja-${k}, 1)` } as CSSProperties}>
                {line.ja}
              </p>
            ))}
          </div>
          <div className="lp-subs">
            {talk.lines.map((line, k) => (
              <p
                key={k}
                className="lp-sub"
                data-lp-find={`sub-${k}`}
                style={{ "--lp-s": `var(--lp-sweep-${k}, 1)`, "--lp-o": `var(--lp-sub-${k}, 1)` } as CSSProperties}
              >
                <span className="lp-sub-text">{line.zh}</span>
              </p>
            ))}
          </div>
        </section>
        <Call speaker={speaker} copy={call} />
      </div>
    </div>
  );
}
