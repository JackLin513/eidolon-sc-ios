import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { finish } from "./bridge";
import { loadWelcome } from "./data";
import { Landing } from "./landing/Landing";
import "./styles.css";
import "./landing/landing.css";

/**
 * 欢迎页的入口（spec #118）：整页是上游的落地面，原生只留右上角的入口按钮（从 `EnterButton`
 * 回调给 App）。名册读不到或页面起不来时，App 那边会退回它自己的兜底画面。
 */
async function start() {
  const root = createRoot(document.getElementById("root")!);
  try {
    const { characters, assets } = await loadWelcome();
    warmAudio(
      characters.flatMap((character) =>
        [character.greeting?.audio_url, character.call_opener?.audio_url].filter(
          (url): url is string => !!url,
        ),
      ),
    );
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
 * 声音：先把用到的音频用 `preload="auto"` 的元素预热进媒体缓存，再给 `play()` 补一次重试
 * （iOS 第一次播放有时会落空）。AbortError 表示「播放被新的一段顶掉」，不重试。
 */
function warmAudio(urls: string[]) {
  for (const url of urls) {
    const audio = new Audio();
    audio.preload = "auto";
    audio.src = url;
    audio.load();
  }
  const log: string[] = ((window as unknown as { __audioLog?: string[] }).__audioLog ??= []);
  const note = (text: string) => {
    log.push(text);
    if (log.length > 6) log.shift();
    console.log(`[audio] ${text}`);
  };
  const original = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (this: HTMLMediaElement) {
    const before = `rs${this.readyState} ${this.src.startsWith("data:") ? "data" : this.src.slice(-28)}`;
    const started = original.call(this);
    note(`play ${before}`);
    started?.then(
      () => note("  → ok"),
      (error: Error) => {
        note(`  → ${error.name}`);
        if (error.name === "AbortError") return;
        window.setTimeout(
          () => void original.call(this).catch((e: Error) => note(`  retry ${e.name}`)),
          150,
        );
      },
    );
    return started;
  };
}

// 调试：停在某一帧看版式。App 用 `EIDOLON_WELCOME_QUERY` 传过来：
// `act=4` 翻到那一幕，`frac=0.5` 停在整页一半，`scroll=1234` 停在指定像素。
function jumpToAct() {
  const params = new URLSearchParams(location.search);
  if (params.get("debug")) {
    const html = document.documentElement;
    const viewport = window.visualViewport;
    const tag = document.createElement("div");
    tag.textContent = [
      `${html.dataset.lpTier ?? "-"} / ${html.dataset.lpLayout ?? "-"}`,
      `innerW ${window.innerWidth} clientW ${html.clientWidth} visualW ${Math.round(viewport?.width ?? -1)}`,
      `scrollX ${window.scrollX} scrollW ${html.scrollWidth} dpr ${window.devicePixelRatio}`,
      `bodyW ${document.body.getBoundingClientRect().width}`,
    ].join(" · ");
    Object.assign(tag.style, {
      position: "fixed", left: "8px", bottom: "8px", right: "8px", color: "#0f0",
      font: "12px monospace", zIndex: "9999", whiteSpace: "pre-wrap",
    });
    document.body.append(tag);
    window.setInterval(() => {
      const log = (window as unknown as { __audioLog?: string[] }).__audioLog ?? [];
      tag.textContent = [
        `${html.dataset.lpTier ?? "-"} / ${html.dataset.lpLayout ?? "-"}`,
        `innerW ${window.innerWidth} clientW ${html.clientWidth} visualW ${Math.round(viewport?.width ?? -1)}`,
        `scrollX ${window.scrollX} scrollW ${html.scrollWidth} dpr ${window.devicePixelRatio}`,
        `bodyW ${document.body.getBoundingClientRect().width}`,
        ...log.slice(-4),
      ].join("\n");
    }, 500);
  }
  const act = params.get("act");
  const frac = Number(params.get("frac") ?? Number.NaN);
  const pixels = Number(params.get("scroll") ?? Number.NaN);
  if (!act && Number.isNaN(frac) && Number.isNaN(pixels)) return;
  // 等页面把版式和滚动高度算完（动效版是按窗口高度摆的，马上滚会落空）。
  setTimeout(() => {
    if (act) {
      document.querySelector(`[data-lp-act="${act}"]`)?.scrollIntoView({ block: "start" });
    }
    const max = document.documentElement.scrollHeight - window.innerHeight;
    if (!Number.isNaN(frac)) window.scrollTo(0, max * frac);
    else if (!Number.isNaN(pixels)) window.scrollTo(0, pixels);
  }, 900);
}

start().then(jumpToAct);
