import type { CSSProperties } from "react";

import type { Section } from "./model/timeline";
import { EnterButton } from "../EnterButton";

/**
 * 第 6 幕「诚实事项」：完全静止、居中的一段短文，全站最暗、最静的地方，没有任何滚动动画，照常往上走。
 * 文案在服务端排好（登录方式从后端的登录选项读出来，已经写成一句）。运动版式里它的高度是它在时间线上占的屏数。
 */
export function Honesty({ section, title, lines }: { section: Section; title: string; lines: string[] }) {
  return (
    <section
      className="lp-act6"
      data-lp-act="6"
      aria-labelledby="lp-act6-title"
      data-lp-section={section.index}
      style={{ "--lp-screens": section.screens } as CSSProperties}
    >
      <div className="lp-act6-text">
        <h2 id="lp-act6-title" className="lp-act-title">
          {title}
        </h2>
        {lines.map((line) => (
          <p key={line} className="lp-act6-line">
            {line}
          </p>
        ))}
      </div>
    </section>
  );
}

/**
 * 第 7 幕「开始」：28 道光收拢成一块手机屏幕的白光（光层画；静止版式、光层没起来时由 CSS 画出汇聚后的
 * 那块白光），然后出现行动按钮：访客点了在落地页里弹出登录面板，已登录的是「继续」，回到对话列表。
 * 运动版式里文字和按钮跟着模型淡入（--lp-act7，由 LightStage 写）。
 */
export function Start({
  section,
  title,
  body,
  isSignedIn,
  label,
  className,
}: {
  section: Section;
  title: string;
  body: string;
  isSignedIn: boolean;
  label: string;
  className: string;
}) {
  return (
    <div className="lp-stage-wrap lp-start" data-lp-section={section.index} style={{ "--lp-screens": section.screens } as CSSProperties}>
      <section className="lp-stage lp-act7" aria-labelledby="lp-act7-title" data-lp-act="7">
        <div className="lp-screen-static" aria-hidden />
        <div className="lp-act7-copy">
          <div data-lp-find="act7">
            <h2 id="lp-act7-title" className="lp-act-title">
              {title}
            </h2>
            <p className="lp-act-body">{body}</p>
          </div>
          <EnterButton label={label} />
        </div>
      </section>
    </div>
  );
}
