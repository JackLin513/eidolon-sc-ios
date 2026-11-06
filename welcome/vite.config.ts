import { fileURLToPath } from "node:url";

import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

import { TIER_SCRIPT } from "./src/landing/tierScript";

const shim = (path: string) => fileURLToPath(new URL(path, import.meta.url));

export default defineConfig({
  // 页面从 App 的自定义 scheme 里读，资源地址必须是相对的。
  base: "./",
  plugins: [
    react(),
    {
      // 首屏前定档的脚本要同步跑在 <head> 里，和上游 layout 一样。
      name: "welcome-tier-script",
      transformIndexHtml: (html) => html.replace("<!--TIER-->", `<script>${TIER_SCRIPT}</script>`),
    },
  ],
  resolve: {
    alias: [
      { find: "@/components/ui/button", replacement: shim("./src/shims/button.ts") },
      { find: "@/components/conversations/stand/Stand", replacement: shim("./src/shims/stand.ts") },
      { find: "@/lib/api", replacement: shim("./src/shims/api.ts") },
      { find: "@/lib/imageColor", replacement: shim("./src/shims/imageColor.ts") },
      { find: "@/lib/repository", replacement: shim("./src/shims/repository.ts") },
      { find: "@/lib/signIn", replacement: shim("./src/shims/signIn.ts") },
      { find: "@/i18n", replacement: shim("./src/shims/i18n.ts") },
    ],
  },
  build: { outDir: "dist" },
});
