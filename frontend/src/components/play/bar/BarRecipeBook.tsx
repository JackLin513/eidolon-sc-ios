"use client";

import { type PointerEvent, useEffect, useState } from "react";

import type { BarCounterHandle } from "@/components/play/bar/BarCounter";
import { drinkSprite } from "@/components/play/bar/drinkSprites";
import { BAR_INK } from "@/components/play/bar/ink";
import { PixelText } from "@/components/play/bar/PixelText";
import { Sprite } from "@/components/play/bar/Sprite";
import type { BarSound } from "@/components/play/bar/useBarSound";
import { copy } from "@/i18n";
import type { Drink } from "@/lib/api";
import {
  categories,
  COVER,
  drinksIn,
  pageOf,
  RECIPE_TABS,
  type RecipeBookAction,
  recipeBook,
  type RecipeTab,
} from "@/lib/barRecipeBook";

/** Where the book goes over the guest's window (the prototype's VariantA), and its 420×252 CALICOMP window. */
const BOOK = { x: 18, y: 20, width: 420, height: 252 };
/** The white frame in it, and the black page inside that (its own coordinates from here on). */
const PAPER = { x: 4, y: 9, width: 324, height: 234 };
const PAGE = { x: 9, y: 25, width: 315, height: 214 };
/** Each tab's left edge and width along the frame's top (the prototype's `TAB_BOX`). */
const TAB_BOX: Record<RecipeTab, [number, number]> = { name: [9, 62], flavor: [79, 62], kind: [139, 62], bottle: [211, 72] };
/** The page-turning arrows and 「n/24」 under the card. */
const ARROW = { y: 209, width: 23, height: 24, prev: 22, next: 290 };
/** How wide an item of a list takes clicks; by name, a column of letters is this far from the next. */
const ITEM_WIDTH = 200;
const LETTER_COLUMN = 92;

const t = copy.bar.book;

/** What a category is called: an initial as it is, a flavor or kind by the menu's name (「甜味饮品」). */
function categoryName(tab: RecipeTab, key: string): string {
  if (tab === "flavor") return t.category(t.flavors[key as keyof typeof t.flavors]);
  if (tab === "kind") return t.category(t.kinds[key as keyof typeof t.kinds]);
  return key;
}

/** Only a mouse coming over something sounds: a finger has no hover. */
function isMouse(e: PointerEvent<Element>): boolean {
  return e.pointerType === "mouse";
}

/**
 * 配方书（.scratch/bar-room spec「配方书」，坐标照原型 `pieces.tsx` 的 RecipeBook）：调酒时盖住客人窗，进来时从上往下刷开、
 * 响 `boot_up`。CALICOMP 蓝窗里一个白框，顶上四个标签，当前的反白；下面黑色的一页先是封面，点标签出标题和一列灰字分类
 * （按名称是两列大写字母），点分类列出饮品，点饮品看官方中文的配方卡，卡下左右翻页加「n/24」，到头的箭头变淡（lib/barRecipeBook）。
 * 瓶装那一栏点开看图和一句小字，图拖得进摇酒器（BarCounter 的 `drag`，只在调酒台开着时）。
 * 音效：悬停 `mouse_hover`，换标签 `jukeselect`，点分类 `jukepick`，点饮品 `jukechange`，翻页 `jukepick`（到头 `jukechange`）。
 */
export function BarRecipeBook({
  drinks,
  isCounterOpen,
  counter,
  sound,
}: {
  drinks: Drink[];
  isCounterOpen: boolean;
  counter: BarCounterHandle;
  sound: Pick<BarSound, "play">;
}) {
  const [book, setBook] = useState(COVER);
  const [hover, setHover] = useState<string | null>(null);
  const { play } = sound;
  useEffect(() => {
    play("boot_up");
  }, [play]);

  /** Does `action` with the sound `onDone`, or `onRefused` if it changes nothing (null: none). */
  const act = (action: RecipeBookAction, onDone: string | null, onRefused: string | null = null) => {
    const next = recipeBook(book, action, drinks);
    if (next === book) {
      if (onRefused) play(onRefused);
      return;
    }
    if (onDone) play(onDone);
    setBook(next);
    setHover(null);
  };

  /** One grey item of a list, white under the pointer; coordinates on the page. */
  const item = (id: string, text: string, x: number, y: number, onClick: () => void, width = ITEM_WIDTH) => (
    <div key={id}>
      <PixelText x={x} y={y} runs={text} color={hover === id ? BAR_INK.text : BAR_INK.bookGrey} label="" />
      <button
        type="button"
        aria-label={text}
        className="bar-hit absolute"
        style={{ left: x - 4, top: y - 3, width, height: 22 }}
        onPointerEnter={(e) => {
          if (!isMouse(e)) return;
          play("mouse_hover");
          setHover(id);
        }}
        onPointerLeave={() => setHover((h) => (h === id ? null : h))}
        onClick={onClick}
      />
    </div>
  );

  const open = drinks.find((d) => d.id === book.drink) ?? null;
  const page = pageOf(book, drinks);
  let body;
  if (open && open.method !== "bottle" && open.page !== null) {
    body = <Sprite name={`recipe_${open.page}`} x={0} y={0} width={PAGE.width} height={PAGE.height} />;
  } else if (open?.method === "bottle") {
    const bottle = { bottle: open };
    const isDragged = counter.drag.isDragging(bottle);
    body = (
      <>
        <PixelText x={18} y={20} runs={open.name} />
        {!isDragged && <Sprite name={drinkSprite(open.id)} x={39} y={56} width={35} height={53} />}
        <div
          role="img"
          aria-label={t.bottle(open.name)}
          className="absolute"
          style={{
            left: 39,
            top: 56,
            width: 35,
            height: 53,
            touchAction: "none",
            cursor: !isCounterOpen ? undefined : isDragged ? "var(--cur-closed)" : "var(--cur-open)",
          }}
          {...(isCounterOpen ? counter.drag.handlers(bottle) : {})}
        />
        <PixelText x={90} y={75} runs={open.description} color={BAR_INK.bookGrey} />
      </>
    );
  } else if (book.tab === null) {
    body = <Sprite name="recipe_intro" x={0} y={0} width={PAGE.width} height={PAGE.height} />;
  } else if (book.tab === "bottle") {
    body = (
      <>
        <PixelText x={18} y={20} runs={t.search.bottle} />
        {drinksIn("bottle", null, drinks).map((d, i) =>
          item(d.id, d.name, 39, 58 + i * 30, () => act({ type: "drink", id: d.id }, "jukechange")),
        )}
      </>
    );
  } else if (book.category === null) {
    const tab = book.tab;
    body = (
      <>
        <PixelText x={18} y={20} runs={t.search[tab]} />
        {categories(tab, drinks).map((key, i) =>
          item(
            key,
            categoryName(tab, key),
            // 按名称两列，每列四个字母；口味、种类一列。
            tab === "name" ? 39 + Math.floor(i / 4) * LETTER_COLUMN : 39,
            58 + (tab === "name" ? i % 4 : i) * 30,
            () => act({ type: "category", category: key }, "jukepick"),
            tab === "name" ? LETTER_COLUMN : ITEM_WIDTH,
          ),
        )}
      </>
    );
  } else {
    body = (
      <>
        <PixelText x={18} y={20} runs={categoryName(book.tab, book.category)} />
        {drinksIn(book.tab, book.category, drinks).map((d, i) =>
          item(d.id, d.name, 39, 52 + i * 26, () => act({ type: "drink", id: d.id }, "jukechange")),
        )}
      </>
    );
  }

  return (
    <div className="bar-wipe absolute" style={{ left: BOOK.x, top: BOOK.y, width: BOOK.width, height: BOOK.height }}>
      <Sprite name="recipe_bg" x={0} y={0} width={BOOK.width} height={BOOK.height} />
      <div className="absolute" style={{ left: PAPER.x, top: PAPER.y, width: PAPER.width, height: PAPER.height, background: BAR_INK.paper }} />
      {RECIPE_TABS.map((tab) => {
        const [x, width] = TAB_BOX[tab];
        const isActive = book.tab === tab;
        return (
          <div key={tab}>
            {isActive && <div className="absolute" style={{ left: x, top: PAPER.y, width, height: 16, background: BAR_INK.black }} />}
            <PixelText x={x + 3} y={PAPER.y + 1} runs={t.tabs[tab]} color={isActive ? BAR_INK.text : BAR_INK.black} label="" />
            <button
              type="button"
              aria-label={t.tabs[tab]}
              aria-pressed={isActive}
              className="bar-hit absolute"
              style={{ left: x, top: PAPER.y, width, height: 16 }}
              onPointerEnter={(e) => isMouse(e) && play("mouse_hover")}
              onClick={() => act({ type: "tab", tab }, book.tab === tab ? null : "jukeselect")}
            />
          </div>
        );
      })}
      <div
        className="absolute overflow-hidden"
        style={{ left: PAGE.x, top: PAGE.y, width: PAGE.width, height: PAGE.height, background: BAR_INK.black }}
      >
        {body}
      </div>
      {page && (
        <>
          {(
            [
              [-1, ARROW.prev, page.n === 1, t.prev],
              [1, ARROW.next, page.n === page.of, t.next],
            ] as const
          ).map(([step, x, isEnd, label]) => (
            <button
              key={step}
              type="button"
              aria-label={label}
              className="bar-hit absolute"
              style={{ left: x, top: ARROW.y, width: ARROW.width, height: ARROW.height }}
              onPointerEnter={(e) => isMouse(e) && play("mouse_hover")}
              onClick={() => act({ type: "page", step }, "jukepick", "jukechange")}
            >
              <Sprite
                name="arrow"
                x={0}
                y={0}
                width={ARROW.width}
                height={ARROW.height}
                style={{ opacity: isEnd ? 0.3 : 1, transform: step < 0 ? "scaleX(-1)" : undefined }}
              />
            </button>
          ))}
          <PixelText x={142} y={214} width={60} align="center" runs={`${page.n}/${page.of}`} />
        </>
      )}
    </div>
  );
}
