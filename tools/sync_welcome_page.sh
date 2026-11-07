#!/bin/sh
# 把上游的落地页搬进 welcome/（spec #118）：页面源码、素材、立绘播放器，全部原样拷过来，
# 只做几处「从 Next 的页面外壳里摘出来」和「端上容器」的改动（见下面的 python 段）。
# 上游 checkout 只读。
#
#   tools/sync_welcome_page.sh     # 同步源码、素材、立绘播放器，记下上游 commit
#   tools/build_welcome_page.sh    # 再构建成 EidolonIOS/Resources/WelcomePage
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
UPSTREAM=${EIDOLON_UPSTREAM:-$ROOT/../eidolon-sc}
SRC="$UPSTREAM/frontend/src/app/(landing)"
PUBLIC="$UPSTREAM/frontend/public/landing"
DEST="$ROOT/welcome/src/landing"

if [ ! -d "$SRC" ]; then
  echo "找不到上游落地页：$SRC（用 EIDOLON_UPSTREAM 指到别处）" >&2
  exit 2
fi

rm -rf "$DEST"
mkdir -p "$DEST" "$ROOT/welcome/public/landing" "$ROOT/welcome/public/vendor/spine-3.6" "$ROOT/welcome/public/sounds"

# 页面源码：跳过 Next 的页面外壳（page/layout/about）、登录面板、分享卡片、字体子集脚本和测试。
(cd "$SRC" && tar cf - \
  --exclude='page.tsx' --exclude='layout.tsx' --exclude='about' \
  --exclude='SignInPanel.tsx' --exclude='LandingEntry.tsx' \
  --exclude='opengraph-image*' --exclude='*.test.ts' --exclude='CREDITS.md' \
  --exclude='fontText.ts' --exclude='coverage.test.ts' \
  . ) | tar xf - -C "$DEST"

# 第 4 幕那台手机的模型和贴图（上游 public/landing）。
(cd "$PUBLIC" && tar cf - .) | tar xf - -C "$ROOT/welcome/public/landing"

# 接通音和挂断音（上游 public/sounds）：页面按 `/sounds/…` 取，少一份就听不到。
(cd "$UPSTREAM/frontend/public/sounds" && tar cf - .) | tar xf - -C "$ROOT/welcome/public/sounds"

# spine 3.6 的运行时要两份：一份给落地页（如果以后有），一份给立绘那个页面。
cp -R "$UPSTREAM/frontend/public/vendor/spine-3.6/." "$ROOT/welcome/public/vendor/spine-3.6/"

# 欢迎页里的立绘用 App 那套已经验证过的播放器（stand.html + stand-player.js）。
# 上游的 React 封装在这个文档里画几帧会把网页进程带崩（#118 的排查记录），所以走 iframe。
STAND_PAGE="$ROOT/welcome/public/stand"
rm -rf "$STAND_PAGE"
mkdir -p "$STAND_PAGE"
cp "$ROOT/EidolonIOS/Resources/Stand/stand.html" "$STAND_PAGE/stand.html"
cp "$ROOT/EidolonIOS/Resources/Stand/stand-player.js" "$STAND_PAGE/stand-player.js"
cp "$UPSTREAM/frontend/public/vendor/spine-3.6/spine-webgl.js" "$STAND_PAGE/spine-webgl.js"
python3 - "$STAND_PAGE/stand.html" <<'PY'
import sys
from pathlib import Path

page = Path(sys.argv[1])
text = page.read_text()
text = text.replace(
    "default-src 'none'; script-src eidolon-stand:; style-src 'unsafe-inline'; img-src eidolon-stand:; connect-src eidolon-stand:;",
    "default-src 'none'; script-src eidolon-welcome: 'unsafe-inline'; style-src 'unsafe-inline'; img-src eidolon-welcome:; connect-src eidolon-welcome:;",
)
old = '<script src="spine-webgl.js"></script>'
new = """<script>
  // 这个页面嵌在欢迎页的 iframe 里：自己接上播放器的 post（没有原生那一侧），
  // 按 outfit 参数加载，按 loaded 里报回来的 bounds 算相机、按动画表挑轨道。
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.stand = window.webkit.messageHandlers.stand || {
    postMessage: function (message) {
      if (message && message.type === "loaded") {
        bounds = message.bounds;
        animations = message.animations || {};
        applyCamera();
        window.standPlayer.receive({ type: "pose", pose: pose() });
        parent.postMessage({ type: "stand-loaded", url: message.url }, "*");
      }
      if (message && (message.type === "failed" || message.type === "unavailable")) {
        parent.postMessage({ type: "stand-failed" }, "*");
      }
    },
  };

  var bounds = null;
  var animations = {};
  // 说话与否、看哪儿：父页面只管这三样，轨道由下面照 App 的 StandAnimator 挑。
  var direction = { mood: "calm", speaking: false, looking: true };

  var BODY = {
    calm: ["wait"], happy: ["smile1", "smile2"], shy: ["shy1", "shy2", "smile2"],
    surprised: ["surp1", "surp2"], sad: ["sad1", "sad2"], angry: ["anger1", "anger2"],
    thinking: ["think", "think1", "think2", "wait4", "wait"],
  };
  var FACE = {
    calm: ["face_wait"], happy: ["face_smile", "face_smile1", "face_smile2"],
    shy: ["face_shy", "face_shy2"], surprised: ["face_surp"], sad: ["face_sad"],
    angry: ["face_anger", "face_anger1", "face_anger2"], thinking: ["face_serious"],
  };
  var LIP = { calm: "wait", happy: "smile", shy: "shy", surprised: "surp", sad: "sad", angry: "anger", thinking: "serious" };

  function first(names) {
    for (var i = 0; i < names.length; i += 1) if (animations[names[i]] != null) return names[i];
    return null;
  }

  function anyMouth() {
    var names = Object.keys(animations).sort();
    for (var i = 0; i < names.length; i += 1) {
      var name = names[i];
      if (name.indexOf("lip_") === 0 && name !== "lip_a" && animations[name] > 0 && !/_s[0-9]*$/.test(name)) return name;
    }
    return null;
  }

  /** 和 App 里 StandAnimator.pose 一样：按情绪挑身体和表情，说话时张嘴。 */
  function pose() {
    var mood = direction.mood || "calm";
    var mouth = first(["lip_" + LIP[mood], "lip_" + LIP[mood] + "1", "lip_" + LIP[mood] + "2", "lip_smile", "lip_wait"]) || anyMouth();
    return {
      body: first(BODY[mood] || []) || "wait",
      face: first(FACE[mood] || []) || "blank",
      mouth: mouth ? { name: mouth, open: !!direction.speaking } : null,
      eye: direction.looking && animations["eye_front"] != null ? "eye_front" : null,
      nod: null,
    };
  }

  /** 相机：尺寸要等 iframe 排好版才算得对（刚加载时 innerWidth/Height 可能还是 0）。 */
  function applyCamera() {
    if (!bounds) return;
    var w = window.innerWidth;
    var h = window.innerHeight;
    if (!(w > 1) || !(h > 1)) return;
    var aspect = w / h;
    var height = Math.max(bounds.height * 0.85, (bounds.width * 0.7) / aspect) * 1.12;
    var top = bounds.y + bounds.height * 1.03;
    window.standPlayer.receive({
      type: "camera",
      camera: {
        x: bounds.x + bounds.width / 2,
        y: top - height / 2,
        viewportWidth: height * aspect,
        viewportHeight: height,
      },
    });
  }

  window.addEventListener("resize", applyCamera);
  requestAnimationFrame(applyCamera);

  function load(url) {
    window.standPlayer.receive({ type: "load", url: url });
  }

  window.addEventListener("message", function (event) {
    var data = event.data || {};
    if (data.type === "pose") {
      direction.speaking = !!data.speaking;
      if (data.mood) direction.mood = data.mood;
      window.standPlayer.receive({ type: "pose", pose: pose() });
    }
  });
</script>
<script src="spine-webgl.js"></script>"""
assert old in text
text = text.replace(old, new)
old = '<script src="stand-player.js"></script>'
new = """<script src="stand-player.js"></script>
<script>
  var outfit = new URLSearchParams(location.search).get("outfit");
  if (outfit) load(decodeURIComponent(outfit));
  parent.postMessage({ type: "stand-ready" }, "*");
</script>"""
assert old in text
page.write_text(text.replace(old, new))
PY

# 摘掉 Next 的部分：仓库链接、登录入口、页脚的两个链接。
python3 - "$DEST/Landing.tsx" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()


def swap(old, new):
    global text
    assert old in text, old[:60]
    text = text.replace(old, new, 1)


swap('import { REPOSITORY_URL } from "@/lib/repository";\n', "")
swap('import { LandingEntry } from "./LandingEntry";\n', "")
swap("""        <a href={REPOSITORY_URL} target="_blank" rel="noopener noreferrer" className={buttonVariants({ variant: "ghost" })}>
          {copy.app.repositoryLabel}
        </a>
""", "")
# 右上角只剩原生的「跳过」（spec #118）：页面自己的页首入口不留。
swap("""      <header className="lp-top">
        <LandingEntry isSignedIn={isSignedIn} label={entryLabel} className={buttonVariants({ variant: "outline" })} />
      </header>

""", "")
# 页脚的隐私政策和使用条款是上游站点的页面，端上没有；免责声明留着。
swap("""      {/* 用普通的 <a>：next/link 不进落地页首屏的包；隐私政策、使用条款在应用的根 layout 下，跨根 layout 本来就是整页加载。 */}
      <footer className="lp-footer">
        <p>{copy.legal.disclaimer}</p>
        <p className="lp-footer-links">
          <a href="/privacy">{copy.legal.privacy}</a>
          <a href="/terms">{copy.legal.terms}</a>
        </p>
      </footer>
""", """      <footer className="lp-footer">
        <p>{copy.legal.disclaimer}</p>
      </footer>
""")
path.write_text(text)

closing = path.with_name("Closing.tsx")
text = closing.read_text()
text = text.replace('import { LandingEntry } from "./LandingEntry";', 'import { EnterButton } from "../EnterButton";')
text = text.replace("<LandingEntry isSignedIn={isSignedIn} label={label} className={className} />",
                    "<EnterButton label={label} />")
closing.write_text(text)
PY

# 立绘：StandSlot 换成 iframe；第 7 幕竖屏文字居中并补回全角句号的半格。
python3 - "$DEST/StandSlot.tsx" "$DEST/landing.css" <<'PY'
import sys
from pathlib import Path

# 立绘：整份文件直接写出来（上游那个 React 组件和它的 lazy import 都不要）。
Path(sys.argv[1]).write_text("""\
"use client";

import { useEffect, useRef } from "react";

import type { Outfit } from "@/lib/api";

/**
 * 她的立绘（第 2 幕聚焦时、第 4 幕来电时）：交给 iframe 里那份页面画
 * （App 的 stand.html + stand-player.js）。上游的 React 封装在这个文档里画几帧
 * 会把网页进程带崩（#118 的排查记录），这个播放器则完全正常。
 */
export function StandSlot({
  outfit,
  speaking = false,
}: {
  outfit: Outfit;
  // 上游还会传取景、静止档、是否暂停：iframe 里的播放器自己处理这些。
  framing?: string;
  still?: boolean;
  speaking?: boolean;
  paused?: boolean;
}) {
  const frame = useRef<HTMLIFrameElement>(null);
  const speakingNow = useRef(speaking);
  speakingNow.current = speaking;
  // 换人、换衣装才换 src（会重载 iframe）；说话与否只是告诉里面，不重载。
  useEffect(() => {
    frame.current?.contentWindow?.postMessage({ type: "pose", speaking }, "*");
  }, [speaking]);
  // iframe 加载完会喊一声，把当前状态补给它（第一次的 pose 可能在它装监听器之前就发了）。
  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (event.data?.type === "stand-ready") {
        frame.current?.contentWindow?.postMessage({ type: "pose", speaking: speakingNow.current }, "*");
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, []);

  return (
    <iframe
      ref={frame}
      className="lp-stand-frame"
      title=""
      src={`../stand/stand.html?outfit=${encodeURIComponent(outfit.url)}`}
      scrolling="no"
      aria-hidden
      style={{ pointerEvents: "none" }}
    />
  );
}
""")

css = Path(sys.argv[2])
text = css.read_text()
old = """  .lp-act7-copy {
    left: var(--lp-gutter);
    right: 20px;"""
new = """  .lp-act7-copy {
    left: 20px;
    right: 20px;"""
assert old in text
text = text.replace(old, new)
old = """  .lp-act7-copy {
    left: 20px;
    right: 20px;
    top: auto;
    bottom: 9%;
    transform: none;
    text-align: center;
  }"""
new = """  .lp-act7-copy {
    left: 20px;
    right: 20px;
    top: auto;
    bottom: 9%;
    transform: none;
    text-align: center;
  }
  .lp-act7-copy .lp-act-title,
  .lp-act7-copy .lp-act-body {
    /* 末尾的全角句号也算进居中宽度，视觉上会偏左半格；补回来。 */
    padding-left: 1em;
  }"""
assert old in text
text = text.replace(old, new)
text += """
/* 欢迎页里的立绘：iframe 里的页面自己画，这一格不接任何触摸——滑动手势要穿过去到光谱上。 */
.lp-stand-frame {
  display: block;
  width: 100%;
  height: 100%;
  border: 0;
  background: transparent;
  pointer-events: none;
  animation: lp-stand-rise 0.55s cubic-bezier(0.2, 0.7, 0.3, 1) both;
}
@keyframes lp-stand-rise {
  from {
    opacity: 0;
    transform: translateY(6%);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}
"""
css.write_text(text)
PY

# 声音开关在重看时还记得（spec #118 故事 6）。
python3 - "$DEST/interactionStore.ts" <<'PY'
import sys
from pathlib import Path

store = Path(sys.argv[1])
text = store.read_text()
old = """let state: Interaction = INITIAL;
const listeners = new Set<Listener>();"""
new = """/** 声音开关只记在这台手机上：从设置里重看这一页时还是上次那个状态。 */
const SOUND_KEY = "welcome.sound";
const savedSound = (() => {
  try {
    const value = localStorage.getItem(SOUND_KEY);
    return value === "on" || value === "off" ? value : null;
  } catch {
    return null;
  }
})();
let state: Interaction = savedSound ? { ...INITIAL, sound: savedSound } : INITIAL;
const listeners = new Set<Listener>();"""
assert old in text
text = text.replace(old, new)
old = """    if (state !== prev) listeners.forEach((l) => l(prev, state));"""
new = """    if (state !== prev) {
      if (state.sound !== prev.sound && state.sound !== "hidden") {
        try {
          localStorage.setItem(SOUND_KEY, state.sound);
        } catch {
          /* 存不进去就只在这回有效 */
        }
      }
      listeners.forEach((l) => l(prev, state));
    }"""
assert old in text
store.write_text(text.replace(old, new))
PY

# 文案：只留中文，按端上的实情改写第 6、7 幕。
python3 "$ROOT/tools/sync_welcome_copy.py" \
  "$UPSTREAM/frontend/src/i18n/zh.ts" "$ROOT/welcome/src/shims/i18n.ts"

git -C "$UPSTREAM" rev-parse --short HEAD > "$ROOT/welcome/UPSTREAM"
echo "✓ 上游落地页已拷到 welcome/src/landing（上游 $(cat "$ROOT/welcome/UPSTREAM")）"
