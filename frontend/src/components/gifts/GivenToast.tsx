"use client";

import { MarkedAvatar } from "@/components/app/MarkedAvatar";
import { Button } from "@/components/ui/button";
import { copy } from "@/i18n";
import type { Character } from "@/lib/api";

/** 送出后的提示：送给了谁、那句话（`givenNote`）。`key` 让连着送的每一次重新计时、重新淡入。 */
export type GivenNotice = { key: number; character: Character; note: string };

/**
 * 送出后页面底部的提示（DESIGN.md「礼物页」）：前景色底的反色胶囊，她的小头像、一句话、「去对话」；
 * 放在导航外壳的内容区底部（手机上在 dock 上面），由礼物子页 8 秒后收起。不自动跳转。
 */
export function GivenToast({ notice, onGo }: { notice: GivenNotice | null; onGo: (notice: GivenNotice) => void }) {
  return (
    <div role="status" className="pointer-events-none absolute inset-x-0 bottom-4 z-10 flex justify-center px-4">
      {notice && (
        <div
          key={notice.key}
          className="pointer-events-auto flex max-w-md min-w-0 items-center gap-3 rounded-full bg-foreground py-1.5 pr-1.5 pl-2 text-sm text-background shadow-lg motion-safe:animate-in motion-safe:fade-in motion-safe:slide-in-from-bottom-2"
        >
          <MarkedAvatar name={notice.character.name} src={notice.character.avatar_url} size="sm" />
          <span className="line-clamp-2 min-w-0 flex-1 leading-snug">{notice.note}</span>
          <Button size="sm" variant="toast" onClick={() => onGo(notice)}>
            {copy.gifts.given.toConversation}
          </Button>
        </div>
      )}
    </div>
  );
}
