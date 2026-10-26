// The recipe book (.scratch/bar-room spec「配方书」): what it shows as the player looks a drink up
// while mixing, reduced from where they click. Pure: the screen draws it and plays the sounds.
//
// - Four tabs, by name, by flavor, by kind and the bottled; before any is picked, its cover.
// - By name, by flavor and by kind list their categories (the drinks' initials; the menu's five
//   flavors and five kinds); a category lists its drinks, six at most; a drink opens its recipe card.
// - The cards turn one by one in their pages' order, not round: past either end nothing happens.
// - The bottled tab lists the four bottled drinks; one opens to its picture and its line.
// - Only drinks with a card are looked up by name, flavor or kind. No filters together.

import type { Drink, DrinkFlavor, DrinkKind } from "@/lib/api";

export const RECIPE_TABS = ["name", "flavor", "kind", "bottle"] as const;
export type RecipeTab = (typeof RECIPE_TABS)[number];

/** The menu's flavors and kinds, in its order. */
export const FLAVORS: DrinkFlavor[] = ["sweet", "bitter", "sour", "spicy", "bubbly"];
export const KINDS: DrinkKind[] = ["girly", "manly", "classic", "classy", "promo"];

/** The most drinks a category lists. */
export const PER_CATEGORY = 6;

type CardDrink = Exclude<Drink, { method: "bottle" }> & { page: number };

export type RecipeBookState = {
  /** The tab picked; null on the cover. */
  tab: RecipeTab | null;
  /** The category open in it (an initial, a flavor, a kind). */
  category: string | null;
  /** The drink open: its card, or the bottled one's picture. */
  drink: string | null;
};

export type RecipeBookAction =
  | { type: "tab"; tab: RecipeTab }
  | { type: "category"; category: string }
  | { type: "drink"; id: string }
  /** The card before (-1) or after (1). */
  | { type: "page"; step: -1 | 1 };

export const COVER: RecipeBookState = { tab: null, category: null, drink: null };

/** The drinks with a recipe card, in their pages' order. */
export function cards(drinks: Drink[]): CardDrink[] {
  return drinks
    .filter((d): d is CardDrink => d.method !== "bottle" && d.page !== null)
    .sort((a, b) => a.page - b.page);
}

/** What a tab lists first: the initials of the drinks with a card (by name), the five flavors or kinds. */
export function categories(tab: RecipeTab, drinks: Drink[]): string[] {
  if (tab === "flavor") return FLAVORS;
  if (tab === "kind") return KINDS;
  if (tab === "bottle") return [];
  return [...new Set(cards(drinks).map((d) => d.name[0].toUpperCase()))].sort();
}

/** What a category lists, by name, six at most; the bottled tab lists the bottled drinks. */
export function drinksIn(tab: RecipeTab, category: string | null, drinks: Drink[]): Drink[] {
  if (tab === "bottle") return drinks.filter((d) => d.method === "bottle");
  if (category === null) return [];
  const isIn = (d: CardDrink) =>
    tab === "name" ? d.name[0].toUpperCase() === category : tab === "flavor" ? d.flavor === category : d.kind === category;
  return cards(drinks)
    .filter(isIn)
    .sort((a, b) => a.name.localeCompare(b.name))
    .slice(0, PER_CATEGORY);
}

/** Where the open card is among them: the n of 「n/24」, from 1; null when no card is open. */
export function pageOf(state: RecipeBookState, drinks: Drink[]): { n: number; of: number } | null {
  const all = cards(drinks);
  const i = all.findIndex((d) => d.id === state.drink);
  return i < 0 ? null : { n: i + 1, of: all.length };
}

/**
 * The book after a click. One that changes nothing (the tab already open with nothing under it, a
 * page past either end, a category or drink not there) returns the state it was given, the same
 * object, so the screen can tell.
 */
export function recipeBook(state: RecipeBookState, action: RecipeBookAction, drinks: Drink[]): RecipeBookState {
  switch (action.type) {
    case "tab":
      // 点当前的标签回到这一栏的第一层。
      if (state.tab === action.tab && state.category === null && state.drink === null) return state;
      return { tab: action.tab, category: null, drink: null };
    case "category":
      if (state.tab === null || !categories(state.tab, drinks).includes(action.category)) return state;
      return { ...state, category: action.category, drink: null };
    case "drink":
      if (state.tab === null || !drinksIn(state.tab, state.category, drinks).some((d) => d.id === action.id)) return state;
      return { ...state, drink: action.id };
    case "page": {
      const page = pageOf(state, drinks);
      const to = page && cards(drinks)[page.n - 1 + action.step];
      return to ? { ...state, drink: to.id } : state;
    }
  }
}
