import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { finish } from "./bridge";
import { loadWelcome } from "./data";
import { Landing } from "./landing/Landing";
import "./styles.css";
import "./landing/landing.css";

/**
 * 欢迎页的入口（spec #118）：整页是上游的落地面。名册和素材从 App 的 scheme 上读，
 * 读不到或渲染出错时退回 App 自己的兜底画面（黑底 + 名字 + 进入）。
 */
async function start() {
  const root = createRoot(document.getElementById("root")!);
  try {
    const { characters, assets } = await loadWelcome();
    warmAudio();
    root.render(
      <StrictMode>
        <Landing isSignedIn characters={characters} signInOptions={null} assets={assets} />
      </StrictMode>,
    );
  } catch (error) {
    root.render(
      <div className="welcome-fallback">
        <p className="welcome-fallback-name">Eidolon</p>
        <button type="button" className="lp-enter" onClick={() => finish("failed")}>
          进入
        </button>
      </div>,
    );
    console.error(error);
  }
}

/**
 * iOS 第一次 `play()` 有时会落空（资源还没进媒体进程）：失败时 150 ms 后补一次。
 * AbortError 表示「这段播放被下一段顶掉」，不重试。
 */
function warmAudio() {
  const original = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
    const started = original.call(this);
    started?.catch((error: Error) => {
      if (error.name === "AbortError") return;
      window.setTimeout(() => void original.call(this).catch(() => {}), 150);
    });
    return started;
  };
}

start();
