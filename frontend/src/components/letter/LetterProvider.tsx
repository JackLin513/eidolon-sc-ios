"use client";

import { createContext, lazy, Suspense, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react";

import { useDirectory } from "@/components/conversations/ConversationDirectory";
import { getLetter, listLetters, markLetterRead, type Character } from "@/lib/api";
import type { Letter, LetterSummary } from "@/lib/letter";

// 拆信这一层连同它的字体只在拆信时才载入。
const LetterLayer = lazy(() => import("./LetterLayer").then((m) => ({ default: m.LetterLayer })));

type LettersValue = {
  /** 所有的信，最新的在前；还没拉到时为 null。 */
  letters: LetterSummary[] | null;
  /** 写信的人，按角色 id。 */
  writers: Map<string, Character>;
  /** 拆开一封：取到信以后整屏出现她的信封；收起时信飞回 `target`（不在屏幕上时原地淡出）。 */
  open: (letter: LetterSummary, target: RefObject<HTMLElement | null>) => void;
};

const LettersContext = createContext<LettersValue | null>(null);

export function useLetters(): LettersValue {
  const value = useContext(LettersContext);
  if (!value) throw new Error("useLetters 要在 LetterProvider 里面用");
  return value;
}

/**
 * 信（GLOSSARY.md「信」）由导航外壳持有：所有的信的列表（载入时拉一次，切回这个标签页时再拉一次，拉不到就保持上一次的），
 * 和正在拆的那一封。拆开（信纸展开）就标读过，换一台设备也算读过。
 */
export function LetterProvider({ children }: { children: ReactNode }) {
  const { characters } = useDirectory();
  const [letters, setLetters] = useState<LetterSummary[] | null>(null);
  const [opened, setOpened] = useState<{ letter: Letter; target: RefObject<HTMLElement | null> } | null>(null);
  const opening = useRef(false);

  const load = useCallback(() => {
    listLetters().then(setLetters, () => {}); // 信不是要紧的事，拉不到就保持上一次的
  }, []);

  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") load();
    };
    load();
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);

  const writers = useMemo(() => new Map((characters ?? []).map((c) => [c.id, c])), [characters]);

  const open = useCallback((summary: LetterSummary, target: RefObject<HTMLElement | null>) => {
    if (opening.current) return;
    opening.current = true;
    getLetter(summary.id).then(
      (letter) => setOpened({ letter, target }),
      () => {
        opening.current = false; // 取不到就不拆，再点一次再取
      },
    );
  }, []);

  const onRead = useCallback(() => {
    if (!opened) return;
    const id = opened.letter.id;
    setLetters((all) => all && all.map((l) => (l.id === id ? { ...l, read: true } : l)));
    markLetterRead(id).catch(() => {}); // 没记上的话，下次拉列表时还是没读过
  }, [opened]);

  const onClosed = useCallback(() => {
    opening.current = false;
    setOpened(null);
  }, []);

  const writer = opened ? writers.get(opened.letter.character_id) : undefined;

  return (
    <LettersContext.Provider value={{ letters, writers, open }}>
      {children}
      {opened && writer && (
        <Suspense fallback={null}>
          <LetterLayer
            key={opened.letter.id}
            writer={writer}
            letter={opened.letter}
            target={opened.target}
            onRead={onRead}
            onClosed={onClosed}
          />
        </Suspense>
      )}
    </LettersContext.Provider>
  );
}
