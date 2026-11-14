#!/usr/bin/env python3
"""Fetch named UnityFS bundles straight from the MLTD asset CDN.

The MLTD manifest lists every asset as `{name: [hash, file_name, size]}`. The CDN
serves those files under a version- and platform-scoped prefix, so the URL is
derived rather than stored. This module only does the derivation and the fetch;
it never inspects bundle contents.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ASSET_HOST = "https://td-assets.bn765.com"
PATH_PREFIX = "production/2018"
USER_AGENT = "UnityPlayer/2020.3.32f1 (UnityWebRequest/1.0, libcurl/7.80.0-DEV)"

_PLATFORM_SEGMENTS = {"ios": "iOS", "android": "Android"}


class UnknownPlatform(ValueError):
    """Raised when the platform has no segment in the CDN's URL layout."""


class MissingAsset(LookupError):
    """Raised when a requested asset is not in the manifest."""


@dataclass(frozen=True)
class AssetEntry:
    name: str
    hash: str
    file: str
    size: int


def parse_manifest(raw: object) -> dict[str, AssetEntry]:
    """Turn the manifest's list-of-single-key-objects into entries by asset name."""
    assets: dict[str, AssetEntry] = {}
    for record in raw:  # type: ignore[union-attr]
        for name, (digest, file_name, size) in record.items():
            assets[name] = AssetEntry(
                name=name, hash=digest, file=file_name, size=int(size)
            )
    return assets


def asset_url(version: int, platform: str, entry: AssetEntry) -> str:
    """The absolute URL the CDN serves this entry from."""
    try:
        segment = _PLATFORM_SEGMENTS[platform.lower()]
    except KeyError:
        raise UnknownPlatform(platform) from None
    return f"{ASSET_HOST}/{version}/{PATH_PREFIX}/{segment}/{entry.file}"


def find_assets(
    assets: dict[str, AssetEntry], names: list[str]
) -> list[AssetEntry]:
    """Look up every requested name, reporting all misses in one error."""
    missing = [name for name in names if name not in assets]
    if missing:
        raise MissingAsset("not in the manifest: " + ", ".join(missing))
    return [assets[name] for name in names]


def download(url: str, destination: Path, size: int) -> Path:
    """Fetch one asset, skipping the transfer when a complete copy already exists."""
    if destination.exists() and destination.stat().st_size == size:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "X-Unity-Version": "2020.3.32f1"}
    )
    with urllib.request.urlopen(request) as response:
        destination.write_bytes(response.read())
    written = destination.stat().st_size
    if written != size:
        raise OSError(f"{destination} is {written} bytes, manifest says {size}")
    return destination


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--version", type=int, required=True)
    parser.add_argument("--platform", default="ios", choices=sorted(_PLATFORM_SEGMENTS))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("assets", nargs="+", help="exact asset file names")
    arguments = parser.parse_args(argv)

    assets = find_assets(
        parse_manifest(json.loads(arguments.manifest.read_text("utf-8"))),
        arguments.assets,
    )
    for entry in assets:
        url = asset_url(arguments.version, arguments.platform, entry)
        path = download(url, arguments.out / entry.name, entry.size)
        print(f"{path} ({entry.size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
