"use client";

import { useEffect, useState } from "react";

import { getSchedule } from "@/lib/schedule";

/**
 * 这个部署开没开日程（.scratch/schedule spec「开关」）：对话页更多菜单的「她的日程」只在开着时有。读一次日程接口；
 * 读到之前和读不到时当作关着。
 */
export function useScheduleOn(): boolean {
  const [isOn, setOn] = useState(false);
  useEffect(() => {
    let current = true;
    getSchedule().then(
      (schedule) => current && setOn(schedule.enabled),
      () => undefined,
    );
    return () => {
      current = false;
    };
  }, []);
  return isOn;
}
