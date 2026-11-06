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

start();
