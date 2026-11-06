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
css.write_text(text.replace(swap_old, swap_new))

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
