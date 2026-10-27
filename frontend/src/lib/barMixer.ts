// The bar counter (.scratch/bar-room spec「调酒台」): what the shaker holds as the player mixes her
// drink, reduced from what they do with it. Pure: the screen draws it and keeps the time (`now`,
// in ms). An action that cannot be done returns the state it was given, the same object, so the
// screen can tell and play `buttonnoclick`.
//
// - Parts of the five ingredients go in one at a time, up to 20 in all, and come out one at a
//   time; ice and ageing are switched on and off. All of that before shaking.
// - Shaken, it shakes slowly, and fast once 5 seconds have gone by; stopped while slow it is
//   mixed, while fast blended. Stopped, it is made into a drink, or broken.
// - A bottled drink goes into the shaker only while it is empty, and nothing else after it.
// - What is made is matched to the catalog as the server matches it (backend `drink_catalog`,
//   GLOSSARY.md「饮品」): the parts but optional Karmotrine, the ice, the ageing and the method
//   all as a recipe has them; all of them doubled is its big glass, unless it is big already;
//   anything else is broken. Only for the screen to show: the server judges what is served.

import type { Drink } from "@/lib/api";

/** The five ingredients, in the bar counter's order (its bottles, the keys Q W E R T). */
export const INGREDIENTS = ["adelhyde", "bronson_extract", "powdered_delta", "flanergide", "karmotrine"] as const;
export type Ingredient = (typeof INGREDIENTS)[number];

/** The most parts the shaker holds. */
export const CAPACITY = 20;
/** Shaken this long, it shakes fast: stopped then, it is blended. */
export const FAST_AFTER_MS = 5000;

type BottledDrink = Extract<Drink, { method: "bottle" }>;
type MixedDrink = Exclude<Drink, { method: "bottle" }>;

/** A drink as made: which, and whether its doubled big glass. */
export type Made = { drink: Drink; big: boolean };

/** What the shaker holds, mixed, as the server takes it (`ServeInput` but for a bottle). */
export type Mixture = Record<Ingredient, number> & { ice: boolean; aged: boolean; method: "mix" | "blend" };

/** The body of `POST /api/bar/visits/{visit_id}/serves`. */
export type ServedBody = Mixture | { method: "bottle"; bottle: string };

export type BarMixerState = {
  parts: Record<Ingredient, number>;
  ice: boolean;
  aged: boolean;
  /** Not shaken yet, shaking since `shakenAt`, or stopped. */
  shake: "still" | "shaking" | "stopped";
  shakenAt: number | null;
  /** How it was shaken, once stopped. */
  method: "mix" | "blend" | null;
  /** What it was made into, once stopped (a bottle put in, that bottle); null while broken. */
  made: Made | null;
  /** The bottled drink put in the shaker. */
  bottle: BottledDrink | null;
  /** The slot's garble, once broken. */
  garble: string | null;
};

export type BarMixerAction =
  | { type: "add"; ingredient: Ingredient }
  | { type: "remove"; ingredient: Ingredient }
  | { type: "ice" }
  | { type: "aged" }
  | { type: "shake"; now: number }
  /** Stopped shaking at `now`, matched against `drinks`; `garble` is what the slot says if broken. */
  | { type: "stop"; now: number; drinks: Drink[]; garble: string }
  /** A bottled drink dragged into the shaker. */
  | { type: "bottle"; drink: Drink }
  /** Poured away. */
  | { type: "reset" }
  /** The server found what was served broken (422): it is, whatever the screen made of it. */
  | { type: "broken"; garble: string };

export function emptyMixer(): BarMixerState {
  return {
    parts: { adelhyde: 0, bronson_extract: 0, powdered_delta: 0, flanergide: 0, karmotrine: 0 },
    ice: false,
    aged: false,
    shake: "still",
    shakenAt: null,
    method: null,
    made: null,
    bottle: null,
    garble: null,
  };
}

/** How many parts are in it. */
export function totalParts(state: BarMixerState): number {
  return INGREDIENTS.reduce((sum, i) => sum + state.parts[i], 0);
}

/** Ingredients may go in and come out, ice and ageing be switched: not shaken, no bottle in. */
export function isTakingIngredients(state: BarMixerState): boolean {
  return state.shake === "still" && state.bottle === null;
}

/** Nothing in it: no parts, no ice, not aged, not shaken, no bottle. */
export function isEmpty(state: BarMixerState): boolean {
  return isTakingIngredients(state) && totalParts(state) === 0 && !state.ice && !state.aged;
}

/** Done with: stopped (made or broken), or a bottle put in. */
export function isFinished(state: BarMixerState): boolean {
  return state.bottle !== null || state.shake === "stopped";
}

export function barMixer(state: BarMixerState, action: BarMixerAction): BarMixerState {
  switch (action.type) {
    case "add": {
      if (!isTakingIngredients(state) || totalParts(state) >= CAPACITY) return state;
      return { ...state, parts: { ...state.parts, [action.ingredient]: state.parts[action.ingredient] + 1 } };
    }
    case "remove": {
      if (!isTakingIngredients(state) || state.parts[action.ingredient] === 0) return state;
      return { ...state, parts: { ...state.parts, [action.ingredient]: state.parts[action.ingredient] - 1 } };
    }
    case "ice":
      return isTakingIngredients(state) ? { ...state, ice: !state.ice } : state;
    case "aged":
      return isTakingIngredients(state) ? { ...state, aged: !state.aged } : state;
    case "shake":
      return isTakingIngredients(state) && totalParts(state) > 0 ? { ...state, shake: "shaking", shakenAt: action.now } : state;
    case "stop": {
      if (state.shake !== "shaking" || state.shakenAt === null) return state;
      const method = action.now - state.shakenAt >= FAST_AFTER_MS ? "blend" : "mix";
      const made = matchDrink(action.drinks, { ...state.parts, ice: state.ice, aged: state.aged, method });
      return { ...state, shake: "stopped", method, made, garble: made ? null : action.garble };
    }
    case "bottle": {
      const { drink } = action;
      if (drink.method !== "bottle" || !isEmpty(state)) return state;
      return { ...state, bottle: drink, made: { drink, big: false } };
    }
    case "reset":
      return isEmpty(state) ? state : emptyMixer();
    case "broken":
      return { ...state, shake: "stopped", made: null, bottle: null, garble: action.garble };
  }
}

/** Shaking slowly or fast at `now`, or still, or stopped. */
export function shakeStage(state: BarMixerState, now: number): "still" | "slow" | "fast" | "stopped" {
  if (state.shake !== "shaking") return state.shake;
  return state.shakenAt !== null && now - state.shakenAt >= FAST_AFTER_MS ? "fast" : "slow";
}

/** It may be served: stopped and not broken, or a bottle put in. */
export function canServe(state: BarMixerState): boolean {
  return state.made !== null && (state.bottle !== null || state.shake === "stopped");
}

/** What is served, as `POST …/serves` takes it; null if it cannot be. */
export function served(state: BarMixerState): ServedBody | null {
  if (!canServe(state)) return null;
  if (state.bottle) return { method: "bottle", bottle: state.bottle.id };
  return { method: state.method!, ...state.parts, ice: state.ice, aged: state.aged };
}

/** What the slot under the shaker says: the short name of what is made, the garble if it broke;
 * nothing before it is stopped. */
export function slotText(state: BarMixerState): string | null {
  if (!isFinished(state)) return null;
  return state.made ? state.made.drink.short_name : state.garble;
}

/** The slot's garble when it breaks (the original's random `##20%!!` and the like). */
export function garble(random: () => number = Math.random): string {
  const chars = "#%!?@&*0123456789";
  return Array.from({ length: 7 }, () => chars[Math.floor(random() * chars.length)]).join("");
}

/** The drink `mixture` is in `drinks` (the catalog of `GET /api/bar`), and whether its big glass;
 * null if broken: over what the shaker holds, or none of the recipes. */
export function matchDrink(drinks: Drink[], mixture: Mixture): Made | null {
  if (INGREDIENTS.reduce((sum, i) => sum + mixture[i], 0) > CAPACITY) return null;
  for (const drink of drinks) {
    if (drink.method === "bottle") continue;
    if (drink.method !== mixture.method || drink.ice !== mixture.ice || drink.aged !== mixture.aged) continue;
    for (const times of drink.big ? [1] : [1, 2]) {
      if (isMadeOf(drink, times, mixture)) return { drink, big: times === 2 };
    }
  }
  return null;
}

function isMadeOf(drink: MixedDrink, times: number, mixture: Mixture): boolean {
  const parts = ["adelhyde", "bronson_extract", "powdered_delta", "flanergide"] as const;
  if (parts.some((i) => drink[i] * times !== mixture[i])) return false;
  return drink.karmotrine === "optional" || drink.karmotrine * times === mixture.karmotrine;
}
