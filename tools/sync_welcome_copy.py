#!/usr/bin/env python3
"""把上游 i18n 的 app / share / landing 三块文案搬到 welcome/src/shims/i18n.ts（spec #118）。

页面不跟语言切换，只留中文；`tools/sync_welcome_page.sh` 每次都调它。
"""

import sys
from pathlib import Path


def block(source: str, name: str) -> str:
    start = source.index(f"  {name}: {{")
    depth = 0
    end = start
    while True:
        char = source[end]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                break
        end += 1
    return source[start : end + 1]


def main() -> None:
    source = Path(sys.argv[1]).read_text(encoding="utf-8")
    target = Path(sys.argv[2])
    parts = ",\n".join(block(source, name) for name in ("app", "share", "landing", "legal"))
    target.write_text(
        "// 落地页的文案（上游 i18n/zh.ts 的 app / share / landing 三块）。"
        "由 tools/sync_welcome_page.sh 生成，不手改。\n"
        f"export const copy = {{\n{parts}\n}};\n"
        "export type Messages = typeof copy;\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
