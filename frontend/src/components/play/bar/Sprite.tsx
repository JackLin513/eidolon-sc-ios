import type { CSSProperties } from "react";

import { cn } from "@/lib/utils";

/** Where one of the bar's images is (`frontend/public/bar/img/`, made by `scripts/bar-assets.py`). */
export function barImage(name: string): string {
  return `/bar/img/${name}.png`;
}

/** One of the bar's images at its place on the logical 640×360 screen, at its own size. */
export function Sprite({
  name,
  x,
  y,
  width,
  height,
  className,
  style,
}: {
  name: string;
  x: number;
  y: number;
  width: number;
  height: number;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <img
      src={barImage(name)}
      alt=""
      draggable={false}
      className={cn("absolute max-w-none", className)}
      style={{ left: x, top: y, width, height, ...style }}
    />
  );
}
