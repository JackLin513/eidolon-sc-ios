import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { finish } from "./bridge";
import { loadWelcome } from "./data";
import { Stand } from "./stand/Stand";
import { CALM } from "./stand/standAnimations";
import "./styles.css";
import "./landing/landing.css";

/**
 * 欢迎页的入口（spec #118）：整页是上游的落地面，原生只留右上角的入口按钮（从 `EnterButton`
 * 回调给 App）。名册读不到或页面起不来时，App 那边会退回它自己的兜底画面。
 */
/**
 * 调试用：把页面日志同时记进 localStorage。真机上网页进程被杀时，屏幕会切到原生兜底，
 * 页面上什么都留不下——下次启动把这一份读出来就能知道死之前走到哪一步。
 */
const debugKey = "welcome.debug";
const debugLog: string[] = (() => {
  try {
    const saved = JSON.parse(localStorage.getItem(debugKey) ?? "[]");
    return Array.isArray(saved) ? saved.slice(-40) : [];
  } catch {
    return [];
  }
})();
function record(text: string) {
  debugLog.push(text);
  if (debugLog.length > 40) debugLog.shift();
  try {
    localStorage.setItem(debugKey, JSON.stringify(debugLog));
  } catch {
    /* 存不进去就只在这回有效 */
  }
}
const consoleLog = console.log.bind(console);
console.log = (...args: unknown[]) => {
  record(args.map(String).join(" "));
  consoleLog(...args);
};

async function start() {
  const root = createRoot(document.getElementById("root")!);
  // 调试：`?stand=1` 只画一位的立绘，用来单独看立绘画不画得出来。
  if (new URLSearchParams(location.search).get("stand")) {
    const base = location.protocol === "eidolon-welcome:" ? "eidolon-welcome://media/" : "/media/";
    root.render(
      <div style={{ position: "fixed", width: 320, height: 640, left: 0, top: 0 }}>
        <Stand
          outfits={[{ id: "stand/1030010010", url: `${base}stand/stand-1030010010/` }]}
          framing="waist"
          isPaused={false}
          entrance="none"
          direction={CALM}
          isReducedMotion={false}
          isStill={false}
          maxPixelRatio={1.5}
        />
      </div>,
    );
    return;
  }
  try {
    const { Landing } = await import("./landing/Landing");
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
  // 不预先解码全部声音：30 段常驻解码出来是几十 MB，立绘一上就撞上内存上限。
  // 只装那个给「第一次播放被挡」补一次的包装。
  void urls;
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
    const metrics = () =>
      [
        `${html.dataset.lpTier ?? "-"} / ${html.dataset.lpLayout ?? "-"}`,
        `innerW ${window.innerWidth} clientW ${html.clientWidth} visualW ${Math.round(viewport?.width ?? -1)}`,
        `scrollX ${window.scrollX} scrollW ${html.scrollWidth} dpr ${window.devicePixelRatio}`,
        `bodyW ${document.body.getBoundingClientRect().width}`,
      ];
    Object.assign(tag.style, {
      position: "fixed", left: "8px", bottom: "8px", right: "8px", color: "#0f0",
      font: "12px monospace", zIndex: "9999", whiteSpace: "pre-wrap",
    });
    document.body.append(tag);
    window.setInterval(() => {
      tag.textContent = [...metrics(), ...debugLog.slice(-8)].join("\n");
    }, 500);
  }
  const act = params.get("act");
  const frac = Number(params.get("frac") ?? Number.NaN);
  const pixels = Number(params.get("scroll") ?? Number.NaN);
  if (!act && Number.isNaN(frac) && Number.isNaN(pixels)) return;
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
