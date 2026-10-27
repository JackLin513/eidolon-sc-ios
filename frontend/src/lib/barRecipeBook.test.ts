import { describe, expect, it } from "vitest";

import { barCatalog } from "@/lib/barCatalogFixture";
import { categories, COVER, drinksIn, pageOf, type RecipeBookAction, recipeBook } from "@/lib/barRecipeBook";

const DRINKS = barCatalog();
const names = (tab: Parameters<typeof drinksIn>[0], category: string | null) =>
  drinksIn(tab, category, DRINKS).map((d) => d.name);

describe("categories", () => {
  it("by name are the initials of the drinks with a card, in order", () => {
    expect(categories("name", DRINKS)).toEqual(["B", "C", "F", "G", "M", "P", "S", "Z"]);
  });

  it("by flavor and by kind are the menu's five each, in the menu's order", () => {
    expect(categories("flavor", DRINKS)).toEqual(["sweet", "bitter", "sour", "spicy", "bubbly"]);
    expect(categories("kind", DRINKS)).toEqual(["girly", "manly", "classic", "classy", "promo"]);
  });

  it("the bottled have none", () => {
    expect(categories("bottle", DRINKS)).toEqual([]);
  });
});

describe("drinksIn", () => {
  it("a letter lists the drinks it starts, by name, six at most", () => {
    expect(names("name", "B")).toEqual(["Bad Touch", "Beer", "Bleeding Jane", "Bloom Light", "Blue Fairy", "Brandtini"]);
    expect(names("name", "Z")).toEqual(["Zen Star"]);
  });

  it("a flavor or a kind lists its drinks with a card, not the bottled", () => {
    expect(names("flavor", "bitter")).toEqual(["Grizzly Temple", "Gut Punch", "Piledriver", "Sunshine Cloud", "Suplex"]);
    expect(names("kind", "classic")).toEqual(["Beer", "Bleeding Jane", "Frothy Water"]);
  });

  it("no category lists more than six", () => {
    for (const tab of ["name", "flavor", "kind"] as const) {
      for (const category of categories(tab, DRINKS)) expect(drinksIn(tab, category, DRINKS).length).toBeLessThanOrEqual(6);
    }
  });

  it("the bottled tab lists the four bottled drinks", () => {
    expect(names("bottle", null)).toEqual(["Absinthe", "Rum", "Mulan Tea", "A Fedora"]);
  });

  it("nothing before a category is picked", () => {
    expect(names("flavor", null)).toEqual([]);
  });
});

describe("recipeBook", () => {
  const click = (...actions: RecipeBookAction[]) => actions.reduce((s, a) => recipeBook(s, a, DRINKS), COVER);


  it("goes tab, category, drink", () => {
    const state = click({ type: "tab", tab: "kind" }, { type: "category", category: "promo" }, { type: "drink", id: "zen-star" });
    expect(state).toEqual({ tab: "kind", category: "promo", drink: "zen-star" });
    expect(pageOf(state, DRINKS)).toEqual({ n: 24, of: 24 });
  });

  it("a tab, clicked from anywhere, opens on its categories; already there, nothing changes", () => {
    const open = click({ type: "tab", tab: "name" }, { type: "category", category: "S" }, { type: "drink", id: "suplex" });
    expect(recipeBook(open, { type: "tab", tab: "flavor" }, DRINKS)).toEqual({ tab: "flavor", category: null, drink: null });
    const back = recipeBook(open, { type: "tab", tab: "name" }, DRINKS);
    expect(back).toEqual({ tab: "name", category: null, drink: null });
    expect(recipeBook(back, { type: "tab", tab: "name" }, DRINKS)).toBe(back);
  });


  it("turns the cards in their pages' order, whatever the category", () => {
    const sugar = click({ type: "tab", tab: "flavor" }, { type: "category", category: "sweet" }, { type: "drink", id: "sugar-rush" });
    expect(pageOf(sugar, DRINKS)).toEqual({ n: 21, of: 24 });
    const next = recipeBook(sugar, { type: "page", step: 1 }, DRINKS);
    expect(next.drink).toBe("sunshine-cloud");
    expect(recipeBook(sugar, { type: "page", step: -1 }, DRINKS).drink).toBe("sparkle-star");
  });

  it("does not turn round past either end", () => {
    const first = click({ type: "tab", tab: "name" }, { type: "category", category: "B" }, { type: "drink", id: "bad-touch" });
    expect(pageOf(first, DRINKS)).toEqual({ n: 1, of: 24 });
    expect(recipeBook(first, { type: "page", step: -1 }, DRINKS)).toBe(first);
    const last = click({ type: "tab", tab: "name" }, { type: "category", category: "Z" }, { type: "drink", id: "zen-star" });
    expect(recipeBook(last, { type: "page", step: 1 }, DRINKS)).toBe(last);
  });

  it("a bottled drink opens without a card to turn", () => {
    const rum = click({ type: "tab", tab: "bottle" }, { type: "drink", id: "rum" });
    expect(rum.drink).toBe("rum");
    expect(pageOf(rum, DRINKS)).toBeNull();
    expect(recipeBook(rum, { type: "page", step: 1 }, DRINKS)).toBe(rum);
  });

  it("only what the page lists can be clicked", () => {
    const sweet = click({ type: "tab", tab: "flavor" }, { type: "category", category: "sweet" });
    expect(recipeBook(sweet, { type: "drink", id: "suplex" }, DRINKS)).toBe(sweet);
    expect(recipeBook(COVER, { type: "category", category: "sweet" }, DRINKS)).toBe(COVER);
  });
});
