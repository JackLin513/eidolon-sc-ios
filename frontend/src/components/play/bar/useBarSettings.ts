"use client";

import { useCallback, useEffect, useRef, useState } from "react";

import { type BarSettings, DEFAULT_SETTINGS, keepSettings, storedSettings } from "@/lib/barSettings";

/**
 * 酒吧的设置（.scratch/bar-room 票 14，lib/barSettings）：两个音量和扫描线，记在这台设备上、按用户分开。
 * 知道是谁以后读出来，之前是默认的；`change(patch)` 改了就记下。
 */
export function useBarSettings(userId: string | null) {
  const [settings, setSettings] = useState<BarSettings>(DEFAULT_SETTINGS);
  const latest = useRef(settings);
  useEffect(() => {
    if (!userId) return;
    const stored = storedSettings(userId);
    latest.current = stored;
    setSettings(stored);
  }, [userId]);
  const change = useCallback(
    (patch: Partial<BarSettings>) => {
      const next = { ...latest.current, ...patch };
      latest.current = next;
      setSettings(next);
      if (userId) keepSettings(userId, next);
    },
    [userId],
  );
  return { settings, change };
}
