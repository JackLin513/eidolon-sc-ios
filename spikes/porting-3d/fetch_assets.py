#!/usr/bin/env python3
"""Download bundles straight from the MLTD asset CDN.

The manifest maps an asset name to `[hash, hash.unity3d, size]`; the CDN serves
that file under a version- and platform-scoped prefix. This fetches a chosen
subset by name prefix and skips anything already on disk with the right size,
so an interrupted run resumes and re-running is cheap.

    V=build/mltd-spike/venv/bin/python
    $V spikes/porting-3d/fetch_assets.py --manifest build/mltd-manifest.bin \\
        --version 1078400 --platform ios --out build/mltd-spike/assets \\
        --prefix chr_anim_ --prefix cb_ --prefix ch_ --jobs 6

The CDN needs the game's `X-Unity-Version` and a UnityWebRequest user agent;
without them some edges answer 403. Read-only with respect to the game.
"""

from __future__ import annotations

import argparse
import msgpack
import sys
import threading
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ASSET_HOST = "https://td-assets.bn765.com"
PATH_PREFIX = "production/2018"
USER_AGENT = "UnityPlayer/2020.3.32f1 (UnityWebRequest/1.0, libcurl/7.80.0-DEV)"
PLATFORMS = {"ios": "iOS", "android": "Android"}

_print_lock = threading.Lock()


def load_manifest(path: Path) -> dict:
    raw = path.read_bytes()
    data = msgpack.unpackb(raw, raw=False, strict_map_key=False)
    if isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict):
        data = data[0]
    return data


def select(manifest: dict, prefixes: tuple[str, ...], exclude: tuple[str, ...]) -> list[tuple[str, str, int]]:
    items = []
    for name, entry in manifest.items():
        if not name.startswith(prefixes):
            continue
        if exclude and name.startswith(exclude):
            continue
        items.append((name, entry[1], int(entry[2])))
    return sorted(items)


def fetch(url: str, target: Path, size: int, name: str) -> str:
    if target.exists() and target.stat().st_size == size:
        return "skip"
    target.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "X-Unity-Version": "2020.3.32f1"}
    )
    temporary = target.with_suffix(target.suffix + ".part")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
    except Exception as error:  # noqa: BLE001 - one bad file must not stop the run
        return f"fail {name}: {error}"
    if len(data) != size:
        return f"fail {name}: got {len(data)} of {size} bytes"
    temporary.write_bytes(data)
    temporary.replace(target)
    return "ok"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--version", type=int, required=True)
    parser.add_argument("--platform", default="ios", choices=sorted(PLATFORMS))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--prefix", action="append", required=True,
                        help="只下这些前缀的资源名，可重复")
    parser.add_argument("--exclude", action="append", default=[],
                        help="跳过这些前缀，可重复")
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--limit", type=int)
    args = parser.parse_args(argv)

    manifest = load_manifest(args.manifest)
    items = select(manifest, tuple(args.prefix), tuple(args.exclude))
    if args.limit:
        items = items[: args.limit]
    total = sum(size for _, _, size in items)
    print(f"{len(items)} 个资源，{total / 1e9:.2f} GB", flush=True)
    if not items:
        return 1

    base = f"{ASSET_HOST}/{args.version}/{PATH_PREFIX}/{PLATFORMS[args.platform]}"
    done = {"ok": 0, "skip": 0, "fail": 0}

    def work(item: tuple[str, str, int]) -> None:
        name, filename, size = item
        state = fetch(f"{base}/{filename}", args.out / name, size, name)
        with _print_lock:
            done[state.split()[0]] = done.get(state.split()[0], 0) + 1
            total_done = sum(done.values())
            if state != "skip" and not state.startswith("ok"):
                print(state, flush=True)
            elif total_done % 100 == 0 or total_done == len(items):
                print(f"[{total_done}/{len(items)}] ok={done['ok']} skip={done['skip']} fail={done['fail']}",
                      flush=True)

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(work, items))
    print(f"完成 ok={done['ok']} skip={done['skip']} fail={done['fail']}")
    return 0 if done["fail"] == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
