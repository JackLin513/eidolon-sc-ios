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
    # 端上没有部署服务、没有账号系统：第 6 幕按这台手机上的实际情况说话，
    # 第 7 幕的入口是「进入」而不是「登录」（spec #118）。
    landing = block(source, "landing")
    for original, ours in {
        "部署服务不向你收费，但每人可能存在使用限额。": "所有模型都由你自己配置、自己付费。",
        "支持 BYOK（自带密钥），密钥只保存于本地": "模型密钥只存在这台手机的钥匙串里",
        "记忆可查看&删除，管理者无法查看": "对话、记忆和好感度只存在这台手机上，可以随时查看和删除",
        "登录以后，挑一位偶像，和她说说话。": "挑一位偶像，和她说说话。",
        'continue: "继续"': 'continue: "进入"',
    }.items():
        assert original in landing, original
        landing = landing.replace(original, ours)
    parts = parts.replace(block(source, "landing"), landing)
    target.write_text(
        "// 落地页的文案（上游 i18n/zh.ts 的 app / share / landing 三块）。"
        "由 tools/sync_welcome_page.sh 生成，不手改。\n"
        f"export const copy = {{\n{parts}\n}};\n"
        "export type Messages = typeof copy;\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
