#!/usr/bin/env python3
"""Fetch a version-pinned MLTD asset snapshot from the public asset server.

Route (verified 2026-11-07):
    api.matsurihi.me/api/mltd/v2/version/latest  -> asset.version + asset.indexName
    https://td-assets.bn765.com/<version>/production/2018/<iOS|Android>/<indexName>
    -> msgpack manifest: {asset name: [hash, file name, size]}
    https://td-assets.bn765.com/<version>/production/2018/<platform>/<file name>

No authentication: only `User-Agent` (UnityPlayer/2020.3.32f1) and
`X-Unity-Version: 2020.3.32f1` are needed. The version/filename pair must come
from the same manifest; mixing versions produces GCS `AccessDenied`.

Usage:
    python3 fetch_snapshot.py --work ~/mltd-work --version latest \
        --names dan_loveig_01.imo.unity3d,chara_shadow.unity3d,chara_soul.unity3d
    python3 fetch_snapshot.py --work ~/mltd-work --version 1078590 --names-file names.txt

Output: $WORK/assets/<version>/manifest.msgpack, version.json, snapshot.json,
        files/<cdn file name> (original CDN names), each with sha256 recorded.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

import ssl

import msgpack

try:
    import certifi

    SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())
except ImportError:  # fall back to the interpreter's default trust store
    SSL_CONTEXT = ssl.create_default_context()

MATSURI = "https://api.matsurihi.me/api/mltd/v2"
ASSET_BASE = "https://td-assets.bn765.com"
PLATFORMS = {"ios": "iOS", "android": "Android"}
USER_AGENT = "UnityPlayer/2020.3.32f1 (UnityWebRequest/1.0, libcurl/7.80.0-DEV)"
UNITY_VERSION = "2020.3.32f1"


def get(url: str, timeout: int = 60) -> bytes:
    request = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "X-Unity-Version": UNITY_VERSION,
    })
    with urllib.request.urlopen(request, timeout=timeout, context=SSL_CONTEXT) as response:
        return response.read()


def latest_version() -> dict:
    raw = json.loads(get(MATSURI + "/version/latest?prettyPrint=false"))
    return {"version": raw["asset"]["version"], "index_name": raw["asset"]["indexName"],
            "updated_at": raw["asset"].get("updatedAt", "")}


def version_info(version: int | None) -> dict:
    if version is None:
        return latest_version()
    raw = json.loads(get(MATSURI + f"/version/assets/{version}?prettyPrint=false"))
    return {"version": raw["version"], "index_name": raw["indexName"],
            "updated_at": raw.get("updatedAt", "")}


def download(url: str, target: Path, expected: int | None) -> None:
    if target.exists() and (expected is None or target.stat().st_size == expected):
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    data = get(url)
    if expected is not None and len(data) != expected:
        target.unlink(missing_ok=True)
        raise SystemExit(f"size mismatch for {url}: got {len(data)}, want {expected}")
    target.write_bytes(data)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", required=True, help="e.g. ~/mltd-work")
    parser.add_argument("--version", default="latest", help="'latest' or a numeric asset version")
    parser.add_argument("--platform", default="ios", choices=sorted(PLATFORMS))
    parser.add_argument("--names", help="comma separated asset names")
    parser.add_argument("--names-file", help="file with one asset name per line")
    parser.add_argument("--manifest-only", action="store_true")
    args = parser.parse_args(argv)

    work = Path(args.work).expanduser().resolve()
    info = latest_version() if args.version == "latest" else version_info(int(args.version))
    version = info["version"]
    root = work / "assets" / str(version)
    files = root / "files"
    files.mkdir(parents=True, exist_ok=True)
    platform = PLATFORMS[args.platform]

    manifest_path = root / "manifest.msgpack"
    manifest_url = f"{ASSET_BASE}/{version}/production/2018/{platform}/{info['index_name']}"
    download(manifest_url, manifest_path, None)
    (root / "version.json").write_text(json.dumps({
        "version": version, "index_name": info["index_name"],
        "updated_at": info["updated_at"], "platform": args.platform,
        "manifest_sha256": sha256(manifest_path),
    }, ensure_ascii=False, indent=2) + "\n")

    raw = msgpack.unpackb(manifest_path.read_bytes(), raw=False, strict_map_key=False)
    manifest = raw[0] if isinstance(raw, list) and raw else raw
    print(f"version {version} ({info['index_name']}), {len(manifest)} manifest entries")

    requested: list[str] = []
    if args.names:
        requested += [n.strip() for n in args.names.split(",") if n.strip()]
    if args.names_file:
        requested += [line.strip() for line in Path(args.names_file).read_text().splitlines()
                      if line.strip() and not line.strip().startswith("#")]

    snapshot = root / "snapshot.json"
    state = json.loads(snapshot.read_text()) if snapshot.exists() else {"assets": {}}
    if not args.manifest_only:
        for name in requested:
            entry = manifest.get(name)
            if entry is None:
                print(f"! not in manifest: {name}", file=sys.stderr)
                continue
            digest, file_name, size = entry
            url = f"{ASSET_BASE}/{version}/production/2018/{platform}/{file_name}"
            target = files / file_name
            download(url, target, int(size))
            state["assets"][name] = {
                "file": str(target.relative_to(root)), "size": int(size),
                "manifest_hash": digest, "sha256": sha256(target), "url": url,
            }
            print(f"+ {name} ({size} bytes)")

    state["version"] = version
    state["index_name"] = info["index_name"]
    state["platform"] = args.platform
    state["manifest_sha256"] = sha256(manifest_path)
    snapshot.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
    print(f"snapshot: {snapshot}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
