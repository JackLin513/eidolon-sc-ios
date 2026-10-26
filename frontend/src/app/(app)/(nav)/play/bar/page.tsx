import "./bar.css";

import { BarSubpage } from "@/components/play/bar/BarSubpage";

/**
 * 酒吧（`/play/bar`）：玩法的子页，但单独一个路由，酒吧的代码、样式和像素字只在这一页加载（不进 `[subpage]` 那一包）。
 */
export default function Bar() {
  return <BarSubpage />;
}
