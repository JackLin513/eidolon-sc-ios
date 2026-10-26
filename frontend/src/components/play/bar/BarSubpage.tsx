"use client";

import { notFound, useRouter } from "next/navigation";
import { useEffect, useState } from "react";

import { BarRoom } from "@/components/play/bar/BarRoom";
import { BarScreen, SideMenu } from "@/components/play/bar/BarScreen";
import { PortraitGuard } from "@/components/play/bar/PortraitGuard";
import { copy } from "@/i18n";
import { type BarState, getBar } from "@/lib/api";
import { playHref } from "@/lib/playRoute";

/**
 * 酒吧（`/play/bar`，.scratch/bar-room spec「入口、路由和外壳」）：在导航外壳里（通话不挂断，ADR-0018），
 * 画面盖住导航栏和 dock，正在通话时通话条照旧在最上面。先读 `GET /api/bar`：读到关着时当作没有这一页（not-found）；
 * 读到之前和读不到时只有一层底色。「离开」回玩法页，浏览器返回也是（从玩法页的卡进来）。
 */
export function BarSubpage() {
  const router = useRouter();
  const [bar, setBar] = useState<BarState | null>(null);
  useEffect(() => {
    getBar().then(setBar, () => {});
  }, []);

  if (bar && !bar.enabled) notFound();
  if (!bar) return <div className="bar-layer absolute inset-0" />;
  return (
    <BarScreen room={<BarRoom />} portrait={<PortraitGuard />}>
      <SideMenu leave={copy.bar.leave} onLeave={() => router.push(playHref())} />
    </BarScreen>
  );
}
