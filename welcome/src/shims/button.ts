// Landing 只用到 buttonVariants 的一个类名（入口按钮）。这里给出同样的类名，
// 不再带 shadcn 的整套主题。
export function buttonVariants(_options?: { variant?: string; size?: string }): string {
  return "lp-enter";
}
