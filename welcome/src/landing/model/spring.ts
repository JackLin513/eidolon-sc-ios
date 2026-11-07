// 自写弹簧（原型 scene.ts 的横滚弹簧）：只让起停更软，不改变终点。第 0 幕用它平滑指针，
// 第 2 幕（ticket 05）用它平滑横移。按固定的小步长积分，结果和帧率无关；卡了很久的一帧也只是多走几步。

export type Spring = { x: number; v: number };

/** 刚度和阻尼比：阻尼比略小于 1，几乎不冲过头，又比临界阻尼跟得紧一点。 */
export type SpringParams = { stiffness: number; damping: number };

const DEFAULTS: SpringParams = { stiffness: 120, damping: 0.92 };
const STEP = 1 / 120;

export const settleSpring = (x: number): Spring => ({ x, v: 0 });

/** 朝 `target` 走 `dt` 秒。 */
export function stepSpring(s: Spring, target: number, dt: number, params: SpringParams = DEFAULTS): Spring {
  if (dt <= 0) return s;
  const k = params.stiffness;
  const c = 2 * Math.sqrt(k) * params.damping;
  const steps = Math.ceil(dt / STEP);
  const h = dt / steps;
  let { x, v } = s;
  for (let n = 0; n < steps; n++) {
    v += (k * (target - x) - c * v) * h;
    x += v * h;
  }
  return { x, v };
}
