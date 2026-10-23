"use client";

import type { ReactNode } from "react";

import { MarkedAvatar } from "@/components/app/MarkedAvatar";
import { TierHeart } from "@/components/app/TierHeart";
import { GiftTile } from "@/components/gifts/GiftTile";
import { Button } from "@/components/ui/button";
import { Drawer, DrawerContent, DrawerDescription, DrawerFooter, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { copy } from "@/i18n";
import { heartOf } from "@/lib/affinity";
import type { Character } from "@/lib/api";
import type { GiftCharacter, GiftInfo } from "@/lib/gifts";
import { cn } from "@/lib/utils";
import { CooldownIcon } from "@/theme/icons";

const t = copy.gifts;

/** 送礼面板正在送的：哪件礼物、还有几件，选了谁（还没选是 null）。 */
export type Giving = { gift: GiftInfo; left: number; to: string | null };

/**
 * 送礼面板（DESIGN.md「玩法页」）：电脑从右边拉出 `Sheet`，手机从底部拉出 `Drawer`。上面是这件的插画、名字、
 * 稀有度和「还有 n 件」；中间「送给谁」是所有角色的头像网格（4 列，顺序和对话列表一样），每格头像、名字、
 * 中性色的档位心形加档名，冷却中的头像淡一些、写沙漏和「冷却中」，照常能选，选中的铺 `bg-muted`；
 * 不标她喜欢什么。底部「送给{角色名}」，没选人时是不可用的「选一位」。中性色，不注入谁的颜色。
 */
export function GivePanel({
  giving,
  isOpen,
  isWide,
  isSending,
  characters,
  statuses,
  onChoose,
  onSend,
  onClose,
}: {
  /** 收起时留着上一次的，收起的动画里内容不消失。 */
  giving: Giving | null;
  isOpen: boolean;
  isWide: boolean;
  isSending: boolean;
  /** 所有角色，按对话列表的顺序。 */
  characters: Character[];
  statuses: Map<string, GiftCharacter>;
  onChoose: (characterId: string) => void;
  onSend: () => void;
  onClose: () => void;
}) {
  const chosen = characters.find((c) => c.id === giving?.to);
  const gift = giving?.gift;
  const description = gift ? `${t.rarity[gift.rarity]} · ${t.give.left(giving.left)}` : "";
  const head = gift && (
    <div className="flex items-center gap-3 text-left">
      <GiftTile gift={gift} size="small" />
      <div className="flex min-w-0 flex-col gap-0.5">
        <Title isWide={isWide}>{gift.name}</Title>
        <Description isWide={isWide}>{description}</Description>
      </div>
    </div>
  );
  const grid = (
    <section aria-labelledby="give-to" className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-4">
      <h3 id="give-to" className="text-sm font-medium">
        {t.give.to}
      </h3>
      <ul className="grid grid-cols-4 gap-x-2 gap-y-3">
        {characters.map((c) => (
          <li key={c.id}>
            <Choice character={c} status={statuses.get(c.id)} isChosen={c.id === giving?.to} onChoose={onChoose} />
          </li>
        ))}
      </ul>
    </section>
  );
  const send = (
    <Button className="w-full" disabled={!chosen || isSending} onClick={onSend}>
      {chosen ? t.give.send(chosen.name) : t.give.choose}
    </Button>
  );
  const openChange = (open: boolean) => !open && onClose();

  if (isWide) {
    return (
      <Sheet open={isOpen} onOpenChange={openChange}>
        <SheetContent>
          {/* 右上角留给关闭键 */}
          <SheetHeader className="pr-12">{head}</SheetHeader>
          {grid}
          <SheetFooter>{send}</SheetFooter>
        </SheetContent>
      </Sheet>
    );
  }
  return (
    <Drawer open={isOpen} onOpenChange={openChange} showSwipeHandle>
      <DrawerContent>
        <DrawerHeader className="pb-4">{head}</DrawerHeader>
        {grid}
        <DrawerFooter className="pt-4">{send}</DrawerFooter>
      </DrawerContent>
    </Drawer>
  );
}

/** 礼物名：面板的标题。 */
function Title({ isWide, children }: { isWide: boolean; children: ReactNode }) {
  const Component = isWide ? SheetTitle : DrawerTitle;
  return <Component>{children}</Component>;
}

/** 稀有度和「还有 n 件」：面板的说明。 */
function Description({ isWide, children }: { isWide: boolean; children: ReactNode }) {
  const Component = isWide ? SheetDescription : DrawerDescription;
  return <Component>{children}</Component>;
}

/** 「送给谁」里的一位：头像（冷却中淡一些）、名字、档位心形加档名，或沙漏加「冷却中」。 */
function Choice({
  character,
  status,
  isChosen,
  onChoose,
}: {
  character: Character;
  status: GiftCharacter | undefined;
  isChosen: boolean;
  onChoose: (characterId: string) => void;
}) {
  const cooling = status?.cooling ?? false;
  return (
    <button
      type="button"
      aria-pressed={isChosen}
      onClick={() => onChoose(character.id)}
      className={cn(
        "flex w-full flex-col items-center gap-1 rounded-xl px-1 py-2 outline-none transition-colors focus-visible:ring-3 focus-visible:ring-ring/50",
        isChosen ? "bg-muted" : "hover:bg-muted/60",
      )}
    >
      <span className={cn("flex", cooling && "opacity-60")}>
        <MarkedAvatar name={character.name} src={character.avatar_url} />
      </span>
      <span className="w-full truncate text-center text-subtitle">{character.name}</span>
      {status && (
        <span className="flex max-w-full min-w-0 items-center gap-1 text-meta text-muted-foreground">
          {cooling ? (
            <CooldownIcon aria-hidden className="size-3.5 shrink-0" />
          ) : (
            <TierHeart heart={heartOf(status.tier)} tone="neutral" size="small" />
          )}
          <span className="truncate">{cooling ? t.give.cooling : copy.conversation.affinity.tiers[status.tier]}</span>
        </span>
      )}
    </button>
  );
}
