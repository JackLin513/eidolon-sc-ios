"use client";

import { useEffect, useState } from "react";

import { toFailure, type Failure } from "@/lib/failure";
import { type CyclesView, getCycles } from "@/lib/cycles";

/**
 * 玩法页第一级和周期子页共用的读取：`GET /api/cycles`，读到之前 `view` 是 null。
 * 记、改、删以后各页用 `setView` 换掉那一位（lib/cycles 的 `withHer`）；写的时候服务器说关着时换成 `{ enabled: false }`。
 */
export function useCycles() {
  const [view, setView] = useState<CyclesView | null>(null);
  const [failure, setFailure] = useState<Failure | null>(null);
  useEffect(() => {
    getCycles().then(setView, (e) => setFailure(toFailure(e)));
  }, []);
  return { view, setView, failure };
}
