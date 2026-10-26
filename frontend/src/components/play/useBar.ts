"use client";

import { useEffect, useState } from "react";

import { type BarState, getBar } from "@/lib/api";

/**
 * 玩法页第一级和酒吧共用的读取：`GET /api/bar`。读到之前 `bar` 是 null；读不到时 `failed`（卡不出现，
 * 酒吧照样画画面，「离开」能用）。
 */
export function useBar() {
  const [bar, setBar] = useState<BarState | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    getBar().then(setBar, () => setFailed(true));
  }, []);
  return { bar, failed };
}
