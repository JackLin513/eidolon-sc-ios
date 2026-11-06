// 立绘组件只用到 `cn` 拼类名；上游那一版还带主题 token，这里不需要。
export function cn(...parts: Array<string | false | null | undefined>): string {
  return parts.filter(Boolean).join(" ");
}
