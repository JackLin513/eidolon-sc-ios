// Tests only: the repository's drink catalog as `GET /api/bar` reads it.

import { readFileSync } from "node:fs";

import type { Drink } from "@/lib/api";

/** The repository's catalog as `GET /api/bar` reads it (backend `Drink.described`), read off
 * `characters/drinks.toml` at run time: the frontend's Docker build has no `characters/`. */
export function barCatalog(): Drink[] {
  const toml = readFileSync(new URL("../../../characters/drinks.toml", import.meta.url), "utf-8");
  const tables: Record<string, unknown>[] = [];
  for (const raw of toml.split("\n")) {
    const line = raw.trim();
    if (line === "[[drinks]]") tables.push({});
    const pair = /^(\w+)\s*=\s*(.+)$/.exec(line);
    if (pair && tables.length > 0) tables[tables.length - 1][pair[1]] = JSON.parse(pair[2]);
  }
  return tables.map(({ name_ja: _, ...t }) => {
    if (t.method === "bottle") return t as Drink;
    const { description: __, ...mixed } = t;
    return { big: false, ...mixed } as Drink;
  });
}
