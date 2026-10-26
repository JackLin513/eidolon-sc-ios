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
} as const;
