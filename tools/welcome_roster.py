#!/usr/bin/env python3
"""把上游落地页上的名册抓成一份随 App 打包的 JSON（spec #118）。

欢迎页必须在**没有任何内容包**的时候也能看，所以它的名册不能来自导入的内容包，只能跟着
App 走。这里做一次性的提取：组合与顺序、偶像编号、名字、印象色与光晕色、招呼的语音文件名，
都从上游落地页的服务端渲染结果里读；中文字幕和中文名从上游的角色配置里读。

用法：

    python3 tools/welcome_roster.py --page /tmp/landing.html \
        --characters ../eidolon-sc/characters/characters.toml \
        --greetings EidolonIOS/Resources/Welcome/greetings \
        --out EidolonIOS/Resources/Welcome/welcome.json

产物（JSON 与语音）进仓库，运行时不再联网。
"""

import argparse
import html
import json
import re
import sys
import tomllib
import urllib.request
from pathlib import Path

BUCKET = "https://stand.hmhnk.top"

SECTION = re.compile(
    r'<section id="lp-unit-(?P<index>\d+)"[^>]*>'
    r'<h2[^>]*class="lp-seg-name"[^>]*>(?P<name>.*?)</h2>'
    r'(?P<body>.*?)</section>',
    re.S,
)
PLATE = re.compile(
    r'<button[^>]*class="lp-plate" data-lp-id="(?P<id>[^"]+)"'
    r'[^>]*style="--her-ink:(?P<ink>#[0-9a-fA-F]{6});--her-halo:(?P<halo>#[0-9a-fA-F]{6})"[^>]*>'
    r'.*?class="lp-no"[^>]*>(?P<number>[^<]*)</span>'
    r'.*?class="lp-name"[^>]*>(?P<name>[^<]*)</span>'
    r'.*?class="lp-hex"[^>]*>(?P<official>#[0-9a-fA-F]{6})</span>',
    re.S,
)
GREETING = re.compile(r"https://stand\.hmhnk\.top/greetings/(?P<id>[a-z0-9-]+)-[0-9a-f]+\.mp3")
# 语气提示（`[shyly] ……`）只给语音合成听，页面上显示的是去掉它以后的原文。
CUE = re.compile(r"^\s*(?:\[[a-z][a-z ,]*\]\s*)+")
CALL_OPENER = re.compile(r"https://stand\.hmhnk\.top/call-openers/(?P<id>[a-z0-9-]+)-[0-9a-f]+\.mp3")
# 第 5 幕浮岛上的体素小人：只有四座岛，每座一位。
VOXELS = re.compile(r"https://stand\.hmhnk\.top/landing-voxels/(?P<id>[a-z0-9-]+)\.json")


def read_page(path: str | None) -> str:
    if path:
        return Path(path).read_text(encoding="utf-8")
    request = urllib.request.Request("https://283ai.hmhnk.top/", headers={"User-Agent": "eidolon-roster"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8")


def characters(path: Path) -> dict[str, dict]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    return {character["id"]: character for character in data["characters"]}


def roster(page: str, characters: dict[str, dict]) -> dict:
    greetings = {m.group("id"): m.group(0) for m in GREETING.finditer(page)}
    openers = {m.group("id"): m.group(0) for m in CALL_OPENER.finditer(page)}
    units = []
    for section in SECTION.finditer(page):
        name = html.unescape(section.group("name")).strip()
        idols = []
        for plate in PLATE.finditer(section.group("body")):
            identifier = plate.group("id")
            character = characters.get(identifier)
            if character is None:
                print(f"warning: {identifier} 不在角色配置里，跳过", file=sys.stderr)
                continue
            idols.append(
                {
                    "id": identifier,
                    "number": plate.group("number").strip(),
                    "name": html.unescape(plate.group("name")).strip(),
                    "nameZh": character.get("name_zh"),
                    "official": plate.group("official").lower(),
                    "ink": plate.group("ink").lower(),
                    "halo": plate.group("halo").lower(),
                    "greeting": Path(greetings.get(identifier, "")).name or None,
                    "greetingJa": without_cue(character.get("greeting")),
                    "subtitle": character.get("greeting_subtitle"),
                }
            )
        if idols:
            units.append({"name": name, "idols": idols})
    return {
        "version": 1,
        "units": units,
        "callOpener": Path(openers.get("mano", "")).name or None,
        "callOpenerJa": without_cue(characters["mano"].get("call_opener")),
        "callOpenerSubtitle": characters["mano"].get("call_opener_subtitle"),
        "callPoster": "mano.webp",
        "voxels": sorted({f"{m.group('id')}.json" for m in VOXELS.finditer(page)}),
        "speaker": "mano",
    }


def without_cue(text: str | None) -> str | None:
    return CUE.sub("", text) if text else None


def download(page: str, directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    urls = (
        [m.group(0) for m in GREETING.finditer(page)]
        + [m.group(0) for m in CALL_OPENER.finditer(page)]
        + [m.group(0) for m in VOXELS.finditer(page)]
    )
    for url in dict.fromkeys(urls):
        # 体素放同级目录：greetings/ 只放声音，voxels/ 只放小人。
        home = directory.parent / "voxels" if "/landing-voxels/" in url else directory
        home.mkdir(parents=True, exist_ok=True)
        target = home / Path(url).name
        if target.exists():
            continue
        print(f"下载 {target.name}", file=sys.stderr)
        request = urllib.request.Request(url, headers={"User-Agent": "eidolon-roster"})
        with urllib.request.urlopen(request, timeout=60) as response:
            target.write_bytes(response.read())


def main() -> None:
    parser = argparse.ArgumentParser(description="把落地页的名册抓成 welcome.json")
    parser.add_argument("--page", help="落地页的 HTML 文件；不给就从上游线上取")
    parser.add_argument(
        "--characters",
        type=Path,
        default=Path("../eidolon-sc/characters/characters.toml"),
        help="上游的角色配置",
    )
    parser.add_argument("--greetings", type=Path, help="把招呼语音下载到这个目录")
    parser.add_argument("--out", type=Path, required=True)
    arguments = parser.parse_args()

    page = read_page(arguments.page)
    if arguments.greetings:
        download(page, arguments.greetings)
    data = roster(page, characters(arguments.characters))
    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    arguments.out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    count = sum(len(unit["idols"]) for unit in data["units"])
    print(f"{len(data['units'])} 个组合、{count} 位 → {arguments.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
