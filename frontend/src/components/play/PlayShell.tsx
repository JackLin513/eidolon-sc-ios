import type { ReactNode } from "react";

import { PageShell } from "@/components/app/PageShell";
import { SubpageHeader } from "@/components/app/SubpageHeader";
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty";
import { copy } from "@/i18n";
import { playHref } from "@/lib/playRoute";
import { PlayIcon } from "@/theme/icons";

const t = copy.play;

/**
 * 玩法页第一级和子页共用的页面（DESIGN.md「玩法页」）：外壳里整块一栏，内容最宽 `max-w-3xl`、居中，手机和电脑同一个版式，
 * 没有第二栏。`overlays` 是内容外面的浮层（抽奖弹窗、送礼面板、送出后的提示）；`footer` 固定在内容底部
 * （手机上在 dock 上方），日历子页的保存条放这里。
 */
export function PlayShell({
  header,
  children,
  overlays,
  footer,
}: {
  header: ReactNode;
  children: ReactNode;
  overlays?: ReactNode;
  footer?: ReactNode;
}) {
  return (
    <PageShell width="full" isInShell header={header} footer={footer}>
      <div className="mx-auto flex w-full max-w-3xl flex-1 flex-col gap-4 px-4 py-6">{children}</div>
      {overlays}
    </PageShell>
  );
}

/** 第一级的页首：「玩法」大标题。 */
export function PlayHeader() {
  return <h1 className="text-list-title">{t.title}</h1>;
}

/** 子页的页首：返回键回第一级（电脑和手机都有）、卡的名字和末端的操作（日历子页的月 / 周切换）。 */
export function PlaySubpageHeader({ title, end }: { title: string; end?: ReactNode }) {
  return <SubpageHeader title={title} backHref={playHref()} end={end} />;
}

/** 好感度和礼物没开放时：礼物、成就两个子页页首下面是这一句（第一级只剩「日历」卡）。 */
export function PlayClosed() {
  return (
    <Empty>
      <EmptyHeader>
        <EmptyMedia variant="icon">
          <PlayIcon />
        </EmptyMedia>
        <EmptyTitle>{t.closed.title}</EmptyTitle>
        <EmptyDescription>{t.closed.description}</EmptyDescription>
      </EmptyHeader>
    </Empty>
  );
}
