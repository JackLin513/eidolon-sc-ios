import type { CSSProperties } from "react";

import type { Messages } from "@/i18n";

import { MemoryStill } from "./MemoryStill";
import { MEMORY_STILL, type Actor } from "./model/memory";
import { linesOf, type Line } from "./model/memoryStory";
import type { Section } from "./model/timeline";

export type MemoryCopy = Messages["landing"]["act5"];

/**
 * 第 5 幕「记忆」：一件事被一位偶像收进记忆、传给另一位、再从她那里传开。服务端渲染，客户端 JS 只有静止图那一小块
 * （MemoryStill：加载不到时拿掉）。
 *
 * 运动版式里画面是一块 three.js 画布（memoryLayer.ts）：夜空、四座浮岛和站在上面的几位演员，镜头随滚动推近、
 * 拉远、转向。画布由 LightStage 滚到这一幕附近时建、放在这一幕的最前面，固定铺满视口，不透明度和标题正文的
 * 不透明度都由落地页模型给（--lp-memory、--lp-act5）。几个人说的话是 DOM 上的气泡，按出现的顺序排（读屏器照这个
 * 顺序读，一直在无障碍树上）：LightStage 按落地页模型（model/memoryStory.ts）把每句摆到说话的人头顶、她的记忆柱上，
 * 只在它那一段里显出来；最后一句在全景里淡入。气泡前面藏着说话的人的名字，给读屏器念。某位演员不在名单里时，
 * 她的话不出现（linesOf）。画布丢了上下文、建不起来时，LightStage 给 .lp-root 加上 lp-memory-lost：画面正中换成事先渲染好的
 * 终局全景图（`stillUrl`，存储桶上的），几句话收起来，标题正文和最后一句照旧。
 *
 * 静止版式（定格档、静态档）里这一幕不钉住：最上面是那张全景图，下面是标题、正文，按顺序列出这几句和最后一句。没有图
 * （没配存储桶）、加载不到时只有文字。
 */
export function Memory({
  section,
  copy,
  actors,
  stillUrl,
}: {
  section: Section;
  copy: MemoryCopy;
  actors: readonly Actor[];
  /** 事先渲染好的终局全景图的地址；没有时是 null。 */
  stillUrl: string | null;
}) {
  const actorOf = new Map(actors.map((a) => [a.island, a]));
  const lines = linesOf(actors.map((a) => a.island));
  const vars = { "--lp-screens": section.screens, "--lp-sender": actorOf.get(0)?.color, "--lp-still-aspect": MEMORY_STILL.w / MEMORY_STILL.h };
  return (
    <div className="lp-stage-wrap lp-memory" data-lp-section={section.index} style={vars as CSSProperties}>
      <section className="lp-stage lp-act5" aria-labelledby="lp-act5-title" data-lp-act="5">
        {stillUrl && <MemoryStill src={stillUrl} />}
        <div className="lp-act5-copy" data-lp-find="act5">
          <h2 id="lp-act5-title" className="lp-act-title">
            {copy.title}
          </h2>
          <p className="lp-act-body">{copy.body}</p>
        </div>
        {lines.length > 0 && (
          <div className="lp-lines">
            {lines.map((line) => (
              <Said key={line.key} line={line} copy={copy} name={actorOf.get(line.island)!.name} />
            ))}
          </div>
        )}
        <p className="lp-closing" data-lp-find="memory-closing">
          {copy.closing}
        </p>
      </section>
    </div>
  );
}

/** 一句话：制作人的深蓝气泡，她的白气泡（日语原文在上、中文字幕在下）和「思考中」，柱子上的「想起」标签。 */
function Said({ line, copy, name }: { line: Line; copy: MemoryCopy; name: string }) {
  const props = { className: `lp-line lp-line-${line.kind}`, "data-lp-line": line.key, "data-lp-find": `memory-${line.key}` };
  // 一整段字：拆成两个文字节点时无障碍树上也是两段。
  const by = (who: string) => <span className="sr-only">{`${who}：`}</span>;
  switch (line.kind) {
    case "producer":
      return (
        <p {...props}>
          {by(copy.producer.name)}
          {copy.producer.line}
        </p>
      );
    case "thinking":
      return (
        <p {...props}>
          {by(name)}
          {copy.thinking}
        </p>
      );
    case "recalled":
      return (
        <p {...props}>
          <span className="lp-line-swatch" aria-hidden />
          {by(name)}
          {copy.recalled(copy.from)}
        </p>
      );
    case "said": {
      const said = copy.lines[line.island];
      return (
        <p {...props}>
          {by(name)}
          <span className="lp-line-ja" lang="ja">
            {said.ja}
          </span>
          <span className="lp-line-zh">{said.zh}</span>
        </p>
      );
    }
  }
}
