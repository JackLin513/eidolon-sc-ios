"use client";

import { type PointerEvent, useCallback, useEffect, useRef, useState } from "react";

import type { Drink } from "@/lib/api";
import type { Ingredient } from "@/lib/barMixer";
import { BAR_HEIGHT, BAR_WIDTH } from "@/lib/barScreen";

/** What is dragged into the shaker: a part of an ingredient off the bar counter, or a bottled drink
 * off the recipe book's 「瓶装」 (ticket 09). */
export type Dragged = { ingredient: Ingredient } | { bottle: Drink };

/** The shaker, where a drag lets go to put something in (the original's 72×68 around (513,216)). */
export const SHAKER = { x: 477, y: 182, width: 72, height: 68 };

type Point = { x: number; y: number };

function isOverShaker({ x, y }: Point): boolean {
  return x >= SHAKER.x && x <= SHAKER.x + SHAKER.width && y >= SHAKER.y && y <= SHAKER.y + SHAKER.height;
}

/** Where a pointer is on the logical 640×360 screen it is over. */
function logical(e: PointerEvent<Element>): Point {
  const stage = e.currentTarget.closest(".bar-stage");
  if (!stage) return { x: -1, y: -1 };
  const rect = stage.getBoundingClientRect();
  return { x: ((e.clientX - rect.left) * BAR_WIDTH) / rect.width, y: ((e.clientY - rect.top) * BAR_HEIGHT) / rect.height };
}

function keyOf(item: Dragged): string {
  return "ingredient" in item ? `ingredient:${item.ingredient}` : `bottle:${item.bottle.id}`;
}

/**
 * 拖进摇酒器（.scratch/bar-room spec「调酒台」，原版 a_button_Step_0）：在材料瓶（或配方书的瓶装）上按下，东西跟着指针走，
 * 在摇酒器上松手才放进去（`onDrop`），点一下不算。pointer 事件，鼠标和手指一样；按下时抓住指针，拖出那一格也收得到。
 * `handlers(item)` 展开到能拖的那一格上；`drag` 是正拖着的东西和它在逻辑画面上的位置（画跟着走的瓶子），
 * `isOverShaker` 时摇酒器换「悬停」的图。
 */
export function useShakerDrag(onDrop: (item: Dragged) => void) {
  type Drag = Point & { item: Dragged; pointerId: number };
  const [drag, setDrag] = useState<Drag | null>(null);
  const current = useRef<Drag | null>(null);
  const dropped = useRef(onDrop);
  useEffect(() => {
    dropped.current = onDrop;
  });

  const handlers = useCallback((item: Dragged) => {
    const set = (next: Drag | null) => {
      current.current = next;
      setDrag(next);
    };
    const isMine = (e: PointerEvent<Element>) =>
      current.current !== null && current.current.pointerId === e.pointerId && keyOf(current.current.item) === keyOf(item);
    return {
      onPointerDown(e: PointerEvent<Element>) {
        if (e.button !== 0 || current.current) return;
        e.currentTarget.setPointerCapture(e.pointerId);
        set({ item, pointerId: e.pointerId, ...logical(e) });
      },
      onPointerMove(e: PointerEvent<Element>) {
        if (isMine(e)) set({ ...current.current!, ...logical(e) });
      },
      onPointerUp(e: PointerEvent<Element>) {
        if (!isMine(e)) return;
        set(null);
        if (isOverShaker(logical(e))) dropped.current(item);
      },
      onPointerCancel(e: PointerEvent<Element>) {
        if (isMine(e)) set(null);
      },
    };
  }, []);

  return {
    drag,
    isOverShaker: drag !== null && isOverShaker(drag),
    handlers,
    isDragging: (item: Dragged) => drag !== null && keyOf(drag.item) === keyOf(item),
  };
}

export type ShakerDrag = ReturnType<typeof useShakerDrag>;
