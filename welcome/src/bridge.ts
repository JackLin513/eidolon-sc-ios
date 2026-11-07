/** 页面和 App 之间只有这一件事：告诉它这一页看完了。 */
export function finish(reason: "done" | "failed") {
  window.webkit?.messageHandlers?.welcome?.postMessage({ action: "finish", reason });
}

declare global {
  interface Window {
    webkit?: { messageHandlers?: { welcome?: { postMessage: (message: unknown) => void } } };
  }
}
