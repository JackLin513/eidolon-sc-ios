"use client";

import { useState } from "react";

import { MarkedAvatar } from "@/components/app/MarkedAvatar";
import { TierHeart } from "@/components/app/TierHeart";
import { GiftTile } from "@/components/gifts/GiftTile";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { copy } from "@/i18n";
import { heartOf, type Tier } from "@/lib/affinity";
import type { Character } from "@/lib/api";
import { resetNote, type Resettable } from "@/lib/gifts";
import { BecomesIcon, CooldownIcon } from "@/theme/icons";

const t = copy.gifts.resetCards;

/** 确认框里的一位：她，和她现在的档位。 */
type Pulled = { character: Character; now: Resettable };

/**
 * 重置卡条（DESIGN.md「礼物页」）：有重置卡时才出现的描边圆角块，左边 64px 的重置卡插画，「重置卡 ×n」，下面一句现在用会拉回几位，
 * 右边「使用」（没有可拉回的角色时不可用）。点了先弹 `AlertDialog`，列出会回到信任的每一位和她现在的档位；
 * 确认后交给礼物子页去用（`onUse`），用完了确认框才收起。
 */
export function ResetCards({
  count,
  resettable,
  characters,
  onUse,
}: {
  count: number;
  resettable: Resettable[];
  /** 按对话列表的顺序；确认框照这个顺序列。 */
  characters: Character[];
  onUse: () => Promise<void>;
}) {
  const [isConfirming, setConfirming] = useState(false);
  const [isUsing, setUsing] = useState(false);
  // 打开时的名单：用完以后状态里已经没有可拉回的了，收起的动画里名单不消失。
  const [pulled, setPulled] = useState<Pulled[]>([]);

  function askFirst() {
    const byId = new Map(resettable.map((r) => [r.id, r]));
    setPulled(
      characters.flatMap((character) => {
        const now = byId.get(character.id);
        return now ? [{ character, now }] : [];
      }),
    );
    setConfirming(true);
  }

  async function use() {
    setUsing(true);
    try {
      await onUse();
    } finally {
      setUsing(false);
      setConfirming(false);
    }
  }

  return (
    <section aria-label={t.title} className="flex flex-wrap items-center gap-4 rounded-2xl border px-5 py-4">
      <GiftTile isResetCard size="small" />
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <p className="flex items-baseline gap-2">
          <span className="text-header">{t.title}</span>
          <span aria-hidden className="text-sm text-muted-foreground tabular-nums">
            {t.count(count)}
          </span>
          <span className="sr-only">{t.label(count)}</span>
        </p>
        <p className="text-subtitle text-muted-foreground">{resetNote(resettable.length)}</p>
      </div>
      <Button variant="outline" disabled={resettable.length === 0 || isUsing} onClick={askFirst}>
        {t.use}
      </Button>
      <AlertDialog open={isConfirming} onOpenChange={(open) => !isUsing && setConfirming(open)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t.confirm.title}</AlertDialogTitle>
            <AlertDialogDescription>{t.confirm.description}</AlertDialogDescription>
          </AlertDialogHeader>
          <ul className="flex max-h-[50vh] flex-col gap-3 overflow-y-auto">
            {pulled.map(({ character, now }) => (
              <PulledBack key={character.id} character={character} now={now} />
            ))}
          </ul>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={isUsing}>{copy.common.cancel}</AlertDialogCancel>
            <AlertDialogAction disabled={isUsing} onClick={use}>
              {isUsing && <Spinner data-icon="inline-start" />}
              {t.use}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </section>
  );
}

/** 确认框里的一行：头像、名字，现在的档位（冷却中是沙漏加「冷却中」）→ 信任。 */
function PulledBack({ character, now }: Pulled) {
  const tiers = copy.conversation.affinity.tiers;
  const nowText = now.cooling ? copy.gifts.give.cooling : tiers[now.tier];
  return (
    <li className="flex items-center gap-3">
      <MarkedAvatar name={character.name} src={character.avatar_url} size="sm" />
      <span className="min-w-0 flex-1 truncate text-sm">{character.name}</span>
      <span aria-hidden className="flex shrink-0 items-center gap-1.5 text-meta text-muted-foreground">
        {now.cooling ? <CooldownIcon className="size-3.5 shrink-0" /> : <TierMark tier={now.tier} />}
        {nowText}
        <BecomesIcon className="size-3.5 shrink-0" />
        <TierMark tier="trust" />
        <span className="text-foreground">{tiers.trust}</span>
      </span>
      <span className="sr-only">{t.confirm.becomes(nowText)}</span>
    </li>
  );
}

function TierMark({ tier }: { tier: Tier }) {
  return <TierHeart heart={heartOf(tier)} tone="neutral" size="small" />;
}
