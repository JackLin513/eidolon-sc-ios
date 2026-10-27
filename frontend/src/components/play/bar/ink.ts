// The bar's own colors (.scratch/bar-room spec「像素字」, ADR-0016): the original's frame and the
// prototype's text colors, not the app's palette. Her name is drawn in her official color.

export const BAR_INK = {
  /** Around the screen, and the portrait reminder's ground: the frame's darkest purple. */
  ground: "#1f1a2d",
  /** The body of the text. */
  text: "#ffffff",
  /** Grey words: hints, the order memo's label, her subtitle. */
  sub: "#b9b3c9",
  /** The producer's name (the prototype's 「我」). */
  producer: "#7fb2ff",
  /** The original's pink of the logo and the neon. */
  pink: "#f72b62",
  /** The door's sign between flickers (the prototype's). */
  pinkDim: "#7a1531",
  /** The TV's 「ChN」. */
  channel: "#24ff00",
  black: "#000000",
  /** The veil over the screen under the end card (the prototype's). */
  veil: "rgba(0, 0, 0, 0.6)",
  /** The words on the bar counter's buttons (the prototype's). */
  button: "#111111",
  /** The recipe book's white frame and its tabs. */
  paper: "#ffffff",
  /** The recipe book's grey items, white under the pointer (the prototype's). */
  bookGrey: "#9b9b9b",
  /** The jukebox's yellow: 「点唱机」 while the small player is open, a picked slot's number (the original's). */
  lit: "#ffbb31",
  /** 「点唱机」 with no audio, and the shadow under the small player's title (the original's). */
  off: "#808080",
  /** The jukebox's title box (the prototype's). */
  jukeTitle: "#3c84cf",
  /** The numbers on the jukebox's slots (the prototype's). */
  jukeSlot: "#a6023c",
  /** The jukebox's first line of help (the prototype's). */
  jukeHint: "#fc1783",
} as const;
