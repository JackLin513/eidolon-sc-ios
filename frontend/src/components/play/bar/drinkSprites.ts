// Each drink of the catalog (`characters/drinks.toml`, by id) and its picture in
// `frontend/public/bar/img/` (`drink_<name>`, 35×53 with its middle at (17,26), the bottled ones
// put on the same canvas by `scripts/bar-assets.py`). The original has no picture of Frothy Water
// among those extracted: it borrows Beer's, the nearest of them (bubbly, classic).

const SPRITES: Record<string, string> = {
  "sugar-rush": "srush",
  "sparkle-star": "sstar",
  "blue-fairy": "bfairy",
  "fluffy-dream": "fdream",
  "sunshine-cloud": "scloud",
  moonblast: "moblast",
  "gut-punch": "gpunch",
  piledriver: "pdriver",
  suplex: "splex",
  marsblast: "mablast",
  "crevice-spike": "cspike",
  beer: "beer",
  "bleeding-jane": "bjane",
  "frothy-water": "beer",
  "bad-touch": "btouch",
  brandtini: "btini",
  "cobalt-velvet": "cvelvet",
  "fringe-weaver": "fweaver",
  "mercury-blast": "meblast",
  "grizzly-temple": "gtemple",
  "bloom-light": "blight",
  "zen-star": "zstar",
  "piano-man": "pman",
  "piano-woman": "pwman",
  absinthe: "abs",
  rum: "rum",
  "mulan-tea": "tea",
  "a-fedora": "fed",
};

/** The picture of a drink by its id (`Sprite`'s name); the glitched bottle for one not known. */
export function drinkSprite(id: string): string {
  const name = SPRITES[id];
  return name ? `drink_${name}` : "drink_glitch";
}
