import { Fragment } from "react";

import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { copy } from "@/i18n";
import { CYCLE_GUIDE, type DiagramKind, diagramDays, type GuideSentence } from "@/lib/cycleGuide";
import { cn } from "@/lib/utils";

const t = copy.play.cycles.guide;

/** 讲解里一块的锚点 id，「长短不一」那句链过来时滚到这里。 */
export function guideAnchor(id: string): string {
  return `cycle-guide-${id}`;
}

/**
 * 周期页最下面通栏的讲解七块（.scratch/cycle-page spec「讲解（七块）」）：Accordion 单选、可以全收起，
 * 开着哪块由页面管（「长短不一」那句要能展开「青春期」）。每块导语、几段，每句句末一个小来源链接（新标签页）。
 * 「怎么算的」导语后面放 28 天的示意图。
 */
export function CycleGuide({ open, onOpenChange }: { open: string | null; onOpenChange: (id: string | null) => void }) {
  return (
    <section aria-label={t.title} className="flex flex-col">
      <Accordion
        value={open ? [open] : []}
        onValueChange={(value) => onOpenChange(typeof value[0] === "string" ? value[0] : null)}
      >
        {CYCLE_GUIDE.map((block) => (
          <AccordionItem key={block.id} value={block.id} id={guideAnchor(block.id)} className="scroll-mt-4">
            <AccordionTrigger>{block.title}</AccordionTrigger>
            <AccordionContent>
              <div className="flex max-w-2xl flex-col gap-3">
                <p className="text-muted-foreground">{block.lead}</p>
                {block.hasDiagram && <ExampleDiagram />}
                {block.parts.map((part, i) => (
                  <div key={i} className="flex flex-col gap-1">
                    {part.heading && <h3 className="font-medium">{part.heading}</h3>}
                    <p>
                      {part.sentences.map((sentence, j) => (
                        <Sentence key={j} sentence={sentence} />
                      ))}
                    </p>
                  </div>
                ))}
              </div>
            </AccordionContent>
          </AccordionItem>
        ))}
      </Accordion>
    </section>
  );
}

/** 一句话，来源放在句末标点前：「……约 5 天（NHS、中国指南）。」 */
function Sentence({ sentence }: { sentence: GuideSentence }) {
  const end = /[。？！]$/.test(sentence.text) ? sentence.text.slice(-1) : "";
  const body = end ? sentence.text.slice(0, -1) : sentence.text;
  return (
    <>
      {body}
      <span className="text-meta text-muted-foreground">
        （
        {sentence.sources.map((source, i) => (
          <Fragment key={source.href}>
            {i > 0 && "、"}
            <a href={source.href} target="_blank" rel="noreferrer" className="whitespace-nowrap underline underline-offset-2 hover:text-foreground">
              {source.label}
            </a>
          </Fragment>
        ))}
        ）
      </span>
      {end}
    </>
  );
}

const DIAGRAM_CELL: Record<Exclude<DiagramKind, null> | "none", string> = {
  period: "bg-foreground/60",
  fertile: "bg-foreground/20",
  ovulation: "bg-foreground",
  none: "bg-muted",
};

/** 「怎么算的」里的示意图：以 28 天为例的一条横条，经期第 1–5 天、易孕期第 10–16 天、排卵日第 15 天。不代入任何一位。 */
function ExampleDiagram() {
  const days = diagramDays();
  const marked = new Set([1, 5, 10, 15, 28]);
  return (
    <figure className="flex flex-col gap-2 py-1">
      <div role="img" aria-label={t.diagram.label} className="grid grid-cols-28 gap-px">
        {days.map(({ day, kind }) => (
          <span
            key={day}
            className={cn("h-6 first:rounded-l-md last:rounded-r-md", DIAGRAM_CELL[kind ?? "none"])}
          />
        ))}
      </div>
      <div aria-hidden className="grid grid-cols-28 gap-px text-meta text-muted-foreground tabular-nums">
        {days.map(({ day }) => (
          <span key={day} className="text-center last:text-right">
            {marked.has(day) ? day : ""}
          </span>
        ))}
      </div>
      <ul className="flex flex-wrap gap-x-4 gap-y-1 text-meta text-muted-foreground">
        {(["period", "fertile", "ovulation"] as const).map((kind) => (
          <li key={kind} className="flex items-center gap-1.5">
            <span aria-hidden className={cn("size-3 rounded-sm", DIAGRAM_CELL[kind])} />
            {t.diagram[kind]}
          </li>
        ))}
      </ul>
      <figcaption className="text-meta text-muted-foreground">{t.diagram.caption}</figcaption>
    </figure>
  );
}
