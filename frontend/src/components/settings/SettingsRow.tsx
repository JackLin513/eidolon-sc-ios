"use client";

import NextLink from "next/link";
import type { ComponentType } from "react";

import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { cn } from "@/lib/utils";
import { ExternalLinkIcon, ForwardIcon } from "@/theme/icons";

/** 去哪：站内或别的网站的链接（`href`），或者不离开本页、点了做一件事（`onSelect`，如打开弹窗）。 */
type Target =
  | {
      href: string;
      /** 别的网站，在新标签页打开，行尾换成外链图标；通话照常。 */
      isExternal?: boolean;
      onSelect?: never;
    }
  | { onSelect: () => void; href?: never; isExternal?: never };

type Props = Target & {
  label: string;
  /** 一级列表上名字下面一行当前值的摘要；没有（还没读到、「关于」）时只显示名字。 */
  summary?: string;
  Icon?: ComponentType<{ className?: string; "aria-hidden"?: boolean }>;
  /** 右栏正显示的那一类：电脑上铺中性的 bg-muted（只开 `/settings` 时是档案）。 */
  isCurrent?: boolean;
  /** 网址就是这一类：标 `aria-current="page"`。手机上的一级列表（`/settings`）没有当前页，不标。 */
  isCurrentPage?: boolean;
  /** 行尾的 ›：`narrow` 只在手机上（电脑上靠选中底色），`always` 两种屏宽都有。 */
  chevron?: "narrow" | "always";
};

/**
 * 设置里的一行（DESIGN.md「设置页」）：图标、名字（一级列表上名字下面一行摘要），行尾 › 或外链图标，整行可点，至少 48px 高。
 * 一级列表的每一类、「赞赏」和「关于」的几行都用它。站内的按外壳的去处规则走，通话中离开外壳先问；`onSelect` 的是按钮，不离开本页。
 */
export function SettingsRow({
  href,
  onSelect,
  label,
  summary,
  Icon,
  isCurrent = false,
  isCurrentPage = false,
  chevron = "narrow",
  isExternal = false,
}: Props) {
  const { guard } = useDirectory();
  const className = cn(
    "flex min-h-12 w-full items-center gap-3 px-4 py-2.5 text-body outline-none hover:bg-muted/60 focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:ring-inset",
    isCurrent && "md:bg-muted md:hover:bg-muted",
  );
  const inner = (
    <>
      {Icon && <Icon aria-hidden className="size-5 shrink-0 text-muted-foreground" />}
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate">{label}</span>
        {summary && <span className="truncate text-subtitle text-muted-foreground">{summary}</span>}
      </span>
      {isExternal ? (
        <ExternalLinkIcon aria-hidden className="size-4 shrink-0 text-muted-foreground" />
      ) : (
        <ForwardIcon
          aria-hidden
          className={cn("size-4 shrink-0 text-muted-foreground", chevron === "narrow" && "md:hidden")}
        />
      )}
    </>
  );
  if (href === undefined) {
    return (
      <button type="button" onClick={onSelect} className={cn(className, "text-left")}>
        {inner}
      </button>
    );
  }
  if (isExternal) {
    return (
      <a href={href} target="_blank" rel="noopener noreferrer" className={className}>
        {inner}
      </a>
    );
  }
  return (
    <NextLink
      href={href}
      onClick={guard(href)}
      aria-current={isCurrentPage ? "page" : undefined}
      className={className}
    >
      {inner}
    </NextLink>
  );
}
