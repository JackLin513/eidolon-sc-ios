"use client";

import { useRef, useState } from "react";

import { useDirectory, useWide } from "@/components/conversations/ConversationDirectory";
import { Button } from "@/components/ui/button";
import { Drawer, DrawerContent, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";
import { Empty, EmptyHeader, EmptyTitle } from "@/components/ui/empty";
import { Popover, PopoverContent, PopoverHeader, PopoverTitle, PopoverTrigger } from "@/components/ui/popover";
import { copy } from "@/i18n";
import type { Character } from "@/lib/api";
import { hasUnread, letterDay, showsLetterButton, type LetterSummary } from "@/lib/letter";
import { letterVars } from "@/theme/herVars";
import { LetterIcon } from "@/theme/icons";

import { useLetters } from "./LetterProvider";
import { Seal } from "./Seal";

const t = copy.letter;

/**
 * 对话列表页首、服务状态旁边的信封键（GLOSSARY.md「信」，DESIGN.md「Conversation list」）：部署者开着信、或者用户已经有信时才出现；
 * 有没读过的信时右上角一个点（和公告铃铛的点一样）。点开是所有的信，从新到旧，能滚动：宽屏是挂在键下面、固定高度的 Popover，
 * 窄屏是接近全屏的底部 Drawer。每行一枚她颜色的小信封、她的名字、场合和日期，点了拆开；拆开的信收起时飞回这个键。
 */
export function LetterButton() {
  const { account } = useDirectory();
  const { letters, writers, open } = useLetters();
  const wide = useWide();
  const [isOpen, setOpen] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  if (!showsLetterButton(account?.letters === true, letters)) return null;

  const unread = hasUnread(letters);
  const props = { ref: button, variant: "ghost", size: "icon-lg", "aria-label": unread ? t.boxUnread : t.box, className: "relative" } as const;
  const icon = (
    <>
      <LetterIcon />
      {unread && <span aria-hidden className="absolute top-1.5 right-1.5 size-1.5 rounded-full bg-foreground" />}
    </>
  );
  const pick = (letter: LetterSummary) => {
    setOpen(false);
    open(letter, button);
  };
  const list = <LetterList letters={letters} writers={writers} onPick={pick} />;

  if (wide) {
    return (
      <Popover open={isOpen} onOpenChange={setOpen}>
        <PopoverTrigger render={<Button {...props} />}>{icon}</PopoverTrigger>
        <PopoverContent align="end" className="h-[min(28rem,70dvh)] w-80">
          <PopoverHeader>
            <PopoverTitle>{t.listTitle}</PopoverTitle>
          </PopoverHeader>
          <div className="-mx-2.5 min-h-0 flex-1 overflow-y-auto px-2.5">{list}</div>
        </PopoverContent>
      </Popover>
    );
  }

  return (
    <>
      <Button {...props} onClick={() => setOpen(true)}>
        {icon}
      </Button>
      <Drawer open={isOpen} onOpenChange={setOpen} showSwipeHandle>
        <DrawerContent className="h-[90dvh]">
          <DrawerHeader>
            <DrawerTitle>{t.listTitle}</DrawerTitle>
          </DrawerHeader>
          <div className="min-h-0 flex-1 overflow-y-auto px-4 pt-2 pb-4">{list}</div>
        </DrawerContent>
      </Drawer>
    </>
  );
}

/** 所有的信，从新到旧；写信的人不在角色配置里的不列。 */
function LetterList({
  letters,
  writers,
  onPick,
}: {
  letters: LetterSummary[] | null;
  writers: Map<string, Character>;
  onPick: (letter: LetterSummary) => void;
}) {
  const shown = (letters ?? []).flatMap((letter) => {
    const writer = writers.get(letter.character_id);
    return writer ? [{ letter, writer }] : [];
  });
  if (shown.length === 0) {
    return (
      <Empty>
        <EmptyHeader>
          <EmptyTitle>{t.none}</EmptyTitle>
        </EmptyHeader>
      </Empty>
    );
  }
  const thisYear = new Date().getFullYear();
  return (
    <ul className="flex flex-col gap-2 py-1">
      {shown.map(({ letter, writer }) => (
        <li key={letter.id}>
          <LetterRow letter={letter} writer={writer} thisYear={thisYear} onClick={() => onPick(letter)} />
        </li>
      ))}
    </ul>
  );
}

/** 列表里的一枚小信封：固定浅色，她的颜色只在封蜡和名字上；写着她、场合和日期，没读过的右边一个墨色的点。 */
function LetterRow({
  letter,
  writer,
  thisYear,
  onClick,
}: {
  letter: LetterSummary;
  writer: Character;
  thisYear: number;
  onClick: () => void;
}) {
  const occasion = letter.occasions.map((o) => t.occasions[o]).join("、");
  const day = letterDay(letter.day, thisYear);
  const isUnread = !letter.read;
  return (
    <button
      type="button"
      aria-label={t.row(writer.name, occasion, day, isUnread)}
      onClick={onClick}
      style={letterVars(writer.color)}
      className="flex h-16 w-full items-center gap-3 rounded-md bg-letter-envelope px-3 text-left text-letter-ink ring-1 ring-letter-envelope-edge outline-none transition-transform hover:-translate-y-0.5 focus-visible:ring-3 focus-visible:ring-ring/50"
    >
      <Seal className="size-9 shadow-sm" />
      <span className="flex min-w-0 flex-1 flex-col">
        <span lang="ja" className="truncate font-japanese text-row-name text-her-letter-ink">
          {writer.name}
        </span>
        <span className="truncate text-meta text-letter-muted">
          {occasion} · {day}
        </span>
      </span>
      {isUnread && <span aria-hidden className="size-2 shrink-0 rounded-full bg-letter-ink" />}
    </button>
  );
}
