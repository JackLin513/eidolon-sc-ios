#!/bin/sh
# 把上游的落地页源码搬进 welcome/（spec #118）。上游 checkout 只读，这里只拷不改；
# 拷完做三处小改动（见下面的 python 段），把这页从 Next 的页面外壳里摘出来。
#
#   tools/sync_welcome_page.sh            # 拷源码 + 素材，记下上游 commit
#   tools/build_welcome_page.sh           # 再构建成 EidolonIOS/Resources/WelcomePage
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
mkdir -p "$DEST" "$ROOT/welcome/public/landing"

# 页面源码：跳过 Next 的页面外壳（page/layout/about）、登录面板、分享卡片和测试。
(cd "$SRC" && tar cf - \
  --exclude='page.tsx' --exclude='layout.tsx' --exclude='about' \
  --exclude='SignInPanel.tsx' --exclude='LandingEntry.tsx' \
  --exclude='opengraph-image*' --exclude='*.test.ts' --exclude='CREDITS.md' \
  --exclude='fontText.ts' --exclude='coverage.test.ts' \
  . ) | tar xf - -C "$DEST"

# 第 4 幕那台手机的模型和贴图（上游 public/landing）。
(cd "$PUBLIC" && tar cf - .) | tar xf - -C "$ROOT/welcome/public/landing"

# 立绘：上游通话层那个 React 组件（spine-ts 3.6 画）和它依赖的两个小库、运行时。
STAND_SRC="$UPSTREAM/frontend/src/components/conversations/stand"
mkdir -p "$ROOT/welcome/src/stand" "$ROOT/welcome/public/vendor/spine-3.6"
for name in Stand.tsx StandEngine.ts spineRuntime.ts; do
  cp "$STAND_SRC/$name" "$ROOT/welcome/src/stand/$name"
done
cp "$UPSTREAM/frontend/src/lib/standAnimations.ts" "$ROOT/welcome/src/stand/standAnimations.ts"
cp "$UPSTREAM/frontend/src/lib/standFrames.ts" "$ROOT/welcome/src/stand/standFrames.ts"
cp -R "$UPSTREAM/frontend/public/vendor/spine-3.6/." "$ROOT/welcome/public/vendor/spine-3.6/"

# 立绘内部再打几行日志：死在哪一步（运行时脚本 / 读素材 / 建骨架）。
python3 - "$ROOT/welcome/src/stand" <<'PY'
import sys
from pathlib import Path

home = Path(sys.argv[1])

runtime = home / "spineRuntime.ts"
text = runtime.read_text()
old = '    script.src = SPINE_RUNTIME_URL;'
new = '    console.log("[stand] loading runtime");\n    script.src = SPINE_RUNTIME_URL;'
assert old in text
text = text.replace(old, new)
old = '      const spine = (window as SpineWindow).spine;'
new = '      console.log("[stand] runtime loaded");\n      const spine = (window as SpineWindow).spine;'
assert old in text
runtime.write_text(text.replace(old, new))

engine = home / "StandEngine.ts"
text = engine.read_text()


def swap(old, new):
    global text
    assert old in text, old[:50]
    text = text.replace(old, new, 1)


swap('  private readonly frame = (now: number): void => {',
     '  private frames?: number;\n\n  private readonly frame = (now: number): void => {\n    if (this.frames === undefined) this.frames = 0;\n    if (this.frames++ < 10) console.log("[stand] frame " + this.frames + " @" + Math.round(now));')
swap('    const data = new spine.SkeletonJson(loader).readSkeletonData(this.assets.get(json) as string);',
     '    console.log("[stand] reading skeleton");\n    const data = new spine.SkeletonJson(loader).readSkeletonData(this.assets.get(json) as string);\n    console.log("[stand] skeleton parsed");')
swap('  private start(): void {',
     '  private start(): void {\n    console.log("[stand] starting render");')
swap('    let fetching = this.fetching.get(url);',
     '    console.log("[stand] fetching " + url);\n    let fetching = this.fetching.get(url);')
swap('        .finally(() => this.fetching.delete(url));',
     '        .then(() => console.log("[stand] fetched " + url))\n        .finally(() => this.fetching.delete(url));')
engine.write_text(text)
PY

# 接通音和挂断音（上游 public/sounds）：页面按 `/sounds/…` 取，少一份就听不到。
mkdir -p "$ROOT/welcome/public/sounds"
(cd "$UPSTREAM/frontend/public/sounds" && tar cf - .) | tar xf - -C "$ROOT/welcome/public/sounds"

# 摘掉 Next 的部分：仓库链接换成我们的入口按钮，登录入口换成「进入」。
python3 - "$DEST/Landing.tsx" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

def swap(old, new):
    global text
    assert old in text, old[:60]
    text = text.replace(old, new)

swap('import { REPOSITORY_URL } from "@/lib/repository";\n', "")
swap('import { LandingEntry } from "./LandingEntry";\n', 'import { EnterButton } from "../EnterButton";\n')
swap("""        <a href={REPOSITORY_URL} target="_blank" rel="noopener noreferrer" className={buttonVariants({ variant: "ghost" })}>
          {copy.app.repositoryLabel}
        </a>
""", "")
swap('<LandingEntry isSignedIn={isSignedIn} label={entryLabel} className={buttonVariants({ variant: "outline" })} />',
     '<EnterButton label={entryLabel} />')
# 右上角只剩原生的「跳过」（spec #118）：页面自己的页首入口和仓库链接都不留。
swap("""      <header className="lp-top">
        <EnterButton label={entryLabel} />
      </header>

""", "")
# 页脚的隐私政策和使用条款是上游站点的页面，端上没有（spec #118 范围外）；免责声明留着。
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

# 竖屏第 7 幕：文字的右边留白和左边一样，才真的居中（上游左边让了幕名轨，看着偏右）。
css = path.with_name("landing.css")
text = css.read_text()
swap_old = """  .lp-act7-copy {
    left: var(--lp-gutter);
    right: 20px;"""
swap_new = """  .lp-act7-copy {
    left: 20px;
    right: 20px;"""
assert swap_old in text
text = text.replace(swap_old, swap_new)
# 居中的中文句子末尾要是带个全角句号，字面中心会比视觉中心偏左半个字；
# 这两行统一往右让半格，看起来才是真的居中（标题和正文在这里都以句号结尾）。
swap_old = """  .lp-act7-copy {
    left: 20px;
    right: 20px;
    top: auto;
    bottom: 9%;
    transform: none;
    text-align: center;
  }"""
swap_new = """  .lp-act7-copy {
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
assert swap_old in text
text = text.replace(swap_old, swap_new)
css.write_text(text)

# 立绘这条路上打几行日志：真机上它在哪一步把 WebContent 进程带崩，日志会停在哪一行。
slot = path.with_name("StandSlot.tsx")
text = slot.read_text()
swap_old = 'const Stand = lazy(() => import("@/components/conversations/stand/Stand").then((m) => ({ default: m.Stand })));'
swap_new = """const Stand = lazy(() => {
  console.log("[stand] importing component");
  return import("@/components/conversations/stand/Stand")
    .then((m) => {
      console.log("[stand] component loaded");
      return { default: m.Stand };
    })
    .catch((error) => {
      console.log("[stand] import failed " + String(error));
      throw error;
    });
});"""
assert swap_old in text
slot.write_text(text.replace(swap_old, swap_new))

store = path.with_name("interactionStore.ts")
text = store.read_text()
swap_old = """let state: Interaction = INITIAL;
const listeners = new Set<Listener>();"""
swap_new = """/** 声音开关只记在这台手机上：从设置里重看这一页时还是上次那个状态。 */
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
assert swap_old in text
text = text.replace(swap_old, swap_new)
swap_old = """    if (state !== prev) listeners.forEach((l) => l(prev, state));"""
swap_new = """    if (state !== prev) {
      if (state.sound !== prev.sound && state.sound !== "hidden") {
        try {
          localStorage.setItem(SOUND_KEY, state.sound);
        } catch {
          /* 存不进去就只在这回有效 */
        }
      }
      listeners.forEach((l) => l(prev, state));
    }"""
assert swap_old in text
store.write_text(text.replace(swap_old, swap_new))

closing = path.with_name("Closing.tsx")
text = closing.read_text()
text = text.replace('import { LandingEntry } from "./LandingEntry";', 'import { EnterButton } from "../EnterButton";')
text = text.replace("<LandingEntry isSignedIn={isSignedIn} label={label} className={className} />",
                    "<EnterButton label={label} />")
closing.write_text(text)
PY

python3 "$ROOT/tools/sync_welcome_copy.py" \
  "$UPSTREAM/frontend/src/i18n/zh.ts" "$ROOT/welcome/src/shims/i18n.ts"

git -C "$UPSTREAM" rev-parse --short HEAD > "$ROOT/welcome/UPSTREAM"
echo "✓ 上游落地页已拷到 welcome/src/landing（上游 $(cat "$ROOT/welcome/UPSTREAM")）"
