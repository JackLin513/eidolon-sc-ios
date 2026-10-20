"use client";

import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Drawer, DrawerContent, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";
import { copy } from "@/i18n";
import { achievementRow, COMPLETE, completeRow, type Achievement, type HerAchievements } from "@/lib/achievements";
import { cn } from "@/lib/utils";
import { herVars } from "@/theme/herVars";
import { SuccessIcon, TaskOpenIcon } from "@/theme/icons";

const t = copy.achievements;

/**
 * 「成就」面板（DESIGN.md「Overlays」）：她的对话页更多菜单的「成就」打开，宽屏居中的 Dialog，窄屏底部的 Drawer，
 * 都用她的颜色（同「历史对话」面板）。她的四个成就一行一个（`AchievementLine`），最后一行是「集齐」（`completeRow`）。
 * 新解锁的那几行（`unseen`，成就 id，集齐是 `COMPLETE`）名字旁一个点。
 */
export function AchievementsPanel({
  isOpen,
  onOpenChange,
  isWide,
  color,
  her,
  unseen,
}: {
  isOpen: boolean;
  onOpenChange: (open: boolean) => void;
  isWide: boolean;
  /** 她的官方色。 */
  color: string;
  her: HerAchievements | null;
  unseen: ReadonlySet<string>;
}) {
  const body = her && (
    <ul className="flex flex-col">
      {her.achievements.map((achievement) => (
        <AchievementLine key={achievement.id} achievement={achievement} isUnseen={unseen.has(achievement.id)} />
      ))}
      <CompleteLine her={her} isUnseen={unseen.has(COMPLETE)} />
    </ul>
  );

  // 浮层渲染到对话子树外面，在内容上再注入一次她的颜色（DESIGN.md「The Scoped Colour Rule」）。
  const style = herVars(color);
  if (isWide) {
    return (
      <Dialog open={isOpen} onOpenChange={onOpenChange}>
        <DialogContent style={style} className="flex max-h-[80dvh] flex-col sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>{t.title}</DialogTitle>
          </DialogHeader>
          <div className="min-h-0 overflow-y-auto">{body}</div>
        </DialogContent>
      </Dialog>
    );
  }
  return (
    <Drawer open={isOpen} onOpenChange={onOpenChange} showSwipeHandle>
      <DrawerContent style={style}>
        <DrawerHeader>
          <DrawerTitle>{t.title}</DrawerTitle>
        </DrawerHeader>
        <div className="min-h-0 overflow-y-auto px-4 pb-6">{body}</div>
      </DrawerContent>
    </Drawer>
  );
}

/**
 * 一个成就那一行（`achievementRow`）：名字（新解锁时旁边一个点），下面一行只写下一个阶段，右边阶段点和下一阶段的奖励。
 * 面板和礼物页那一小节共用。
 */
export function AchievementLine({ achievement, isUnseen }: { achievement: Achievement; isUnseen: boolean }) {
  const row = achievementRow(achievement);
  return (
    <li className="flex min-h-14 items-center gap-3 py-1">
      <div className="flex min-w-0 flex-1 flex-col">
        <span className="flex items-center gap-2 text-body">
          {row.name}
          {isUnseen && <UnseenDot />}
        </span>
        <span className="text-meta text-muted-foreground tabular-nums">{row.progress}</span>
      </div>
      <Stages stages={row.stages} />
      <span className="w-14 shrink-0 text-right text-meta text-muted-foreground">{row.reward}</span>
    </li>
  );
}

/** 「集齐」那一行：没集齐是空圈、「集齐」和「重置卡 ×1」，集齐了是勾和「集齐了」。 */
function CompleteLine({ her, isUnseen }: { her: HerAchievements; isUnseen: boolean }) {
  const row = completeRow(her.complete);
  const Icon = row.isComplete ? SuccessIcon : TaskOpenIcon;
  return (
    <li className="flex min-h-14 items-center gap-3 border-t">
      <Icon aria-hidden className={cn("size-5 shrink-0", !row.isComplete && "text-muted-foreground")} />
      <span className={cn("flex min-w-0 flex-1 items-center gap-2 text-body", !row.isComplete && "text-muted-foreground")}>
        {row.name}
        {isUnseen && <UnseenDot />}
      </span>
      {row.reward && <span className="shrink-0 text-meta text-muted-foreground">{row.reward}</span>}
    </li>
  );
}

/** 阶段点：解锁的实心，没解锁的空心（淡）。 */
function Stages({ stages }: { stages: boolean[] }) {
  const unlocked = stages.filter(Boolean).length;
  return (
    <span role="img" aria-label={t.stagesLabel(unlocked, stages.length)} className="flex shrink-0 gap-1">
      {stages.map((isUnlocked, i) => (
        <span key={i} className={cn("size-2 rounded-full", isUnlocked ? "bg-foreground" : "bg-foreground/15")} />
      ))}
    </span>
  );
}

/** 新解锁的点：6px，`bg-foreground`，同导航上的点；读屏读「新解锁」。更多菜单的「成就」后面也用它。 */
export function UnseenDot({ className }: { className?: string }) {
  return (
    <span className={cn("size-1.5 shrink-0 rounded-full bg-foreground", className)}>
      <span className="sr-only">{t.unseen}</span>
    </span>
  );
}
