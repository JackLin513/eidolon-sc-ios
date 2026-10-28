#!/usr/bin/env python3
"""Read-only survey of UnityFS bundles in a game data directory.

This is a probe, not an extractor: it reads only the bundle header's Unity version,
so we can tell whether an old asset tool has any chance before copying anything.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

MAGIC = b"UnityFS\0"
MAX_CSTRING = 256


@dataclass(frozen=True)
class UnityBundleHeader:
    path: Path
    format_version: int
    minimum_player_version: str
    unity_version: str


@dataclass(frozen=True)
class ScanSummary:
    root: Path
    file_count: int
    bundle_count: int
    versions: dict[str, int]
    total_bytes: int

    def as_dict(self) -> dict[str, object]:
        return {
            "root": str(self.root),
            "file_count": self.file_count,
            "bundle_count": self.bundle_count,
            "versions": dict(sorted(self.versions.items())),
            "total_bytes": self.total_bytes,
        }


def _read_cstring(stream) -> str | None:
    data = bytearray()
    while len(data) < MAX_CSTRING:
        byte = stream.read(1)
        if not byte:
            return None
        if byte == b"\0":
            return data.decode("utf-8", errors="replace")
        data.extend(byte)
    return None


def read_unity_bundle_header(path: Path) -> UnityBundleHeader | None:
    """The header fields we need, or None when this file is not a UnityFS bundle."""
    try:
        with path.open("rb") as stream:
            if stream.read(len(MAGIC)) != MAGIC:
                return None
            raw_format = stream.read(4)
            if len(raw_format) != 4:
                return None
            format_version = struct.unpack(">I", raw_format)[0]
            minimum_player_version = _read_cstring(stream)
            unity_version = _read_cstring(stream)
    except OSError:
        return None
    if not minimum_player_version or not unity_version:
        return None
    return UnityBundleHeader(
        path=path,
        format_version=format_version,
        minimum_player_version=minimum_player_version,
        unity_version=unity_version,
    )


def scan(root: Path) -> ScanSummary:
    root = root.resolve()
    file_count = 0
    bundle_count = 0
    total_bytes = 0
    versions: dict[str, int] = {}
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        file_count += 1
        header = read_unity_bundle_header(path)
        if header is None:
            continue
        bundle_count += 1
        total_bytes += path.stat().st_size
        versions[header.unity_version] = versions.get(header.unity_version, 0) + 1
    return ScanSummary(
        root=root,
        file_count=file_count,
        bundle_count=bundle_count,
        versions=versions,
        total_bytes=total_bytes,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="directory to scan")
    parser.add_argument("--json", action="store_true", help="print JSON")
    args = parser.parse_args(argv)
    if not args.root.is_dir():
        parser.error(f"not a directory: {args.root}")
    summary = scan(args.root)
    if args.json:
        print(json.dumps(summary.as_dict(), ensure_ascii=False, indent=2))
    else:
        print(f"files: {summary.file_count}")
        print(f"UnityFS bundles: {summary.bundle_count} ({summary.total_bytes} bytes)")
        for version, count in sorted(summary.versions.items()):
            print(f"  {version}: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
