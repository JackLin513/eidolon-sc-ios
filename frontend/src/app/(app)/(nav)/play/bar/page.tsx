import "./bar.css";

import { connection } from "next/server";

import { BarSubpage } from "@/components/play/bar/BarSubpage";

/**
 * 酒吧（`/play/bar`）：玩法的子页，但单独一个路由，酒吧的代码、样式和像素字只在这一页加载（不进 `[subpage]` 那一包）。
 * 音频在立绘的存储桶（`EIDOLON_STAND_ASSETS_URL`）的 `bar/` 下：这个地址部署时才给，所以每次请求时读（构建时没有）。
 */
export default async function Bar() {
  await connection();
  const assets = process.env.EIDOLON_STAND_ASSETS_URL?.trim().replace(/\/+$/, "") || null;
  return <BarSubpage audioBase={assets && `${assets}/bar`} />;
}
