"""Diff the upstream engine's prompt with the iOS core's, verbatim.

Reports the first difference: the message it falls in, the line and character it starts
at, and a few lines of both sides around it (ADR-0012). Exit code 0 when they are the
same, 1 when they differ.

Usage: python3 tools/oracle/compare.py build/oracle/upstream.json build/oracle/app.json
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def load(path: Path) -> list[dict[str, str]]:
    return json.loads(path.read_text(encoding="utf-8"))


def line_and_column(text: str, index: int) -> tuple[int, int]:
    line = text.count("\n", 0, index) + 1
    column = index - (text.rfind("\n", 0, index) + 1) + 1
    return line, column


def context(text: str, line: int, around: int = 2) -> str:
    lines = text.splitlines()
    first = max(0, line - 1 - around)
    last = min(len(lines), line - 1 + around + 1)
    width = len(str(last))
    return "\n".join(
        f"{'>>' if number == line else '  '} {number:>{width}} | {lines[number - 1]}"
        for number in range(first + 1, last + 1)
    )


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    upstream = load(Path(sys.argv[1]))
    app = load(Path(sys.argv[2]))

    for index in range(max(len(upstream), len(app))):
        if index >= len(upstream):
            print(f"the app has an extra message at {index}: {app[index]['role']}")
            return 1
        if index >= len(app):
            print(f"upstream has an extra message at {index}: {upstream[index]['role']}")
            return 1
        left, right = upstream[index], app[index]
        if left["role"] != right["role"]:
            print(f"message {index}: role upstream {left['role']!r}, app {right['role']!r}")
            return 1
        if left["content"] == right["content"]:
            continue

        a, b = left["content"], right["content"]
        at = next(i for i, (x, y) in enumerate(zip(a, b)) if x != y)
        line, column = line_and_column(a, at)
        app_line, app_column = line_and_column(b, min(at, len(b)))
        print(f"first difference in message {index} ({left['role']})")
        print(f"  upstream line {line}, column {column} (character {at}): {a[at:at + 60]!r}")
        print(f"  app      line {app_line}, column {app_column}: {b[min(at, len(b)):min(at, len(b)) + 60]!r}")
        print()
        print("upstream:")
        print(context(a, line))
        print()
        print("app:")
        print(context(b, app_line))
        return 1

    total = sum(len(message["content"]) for message in upstream)
    print(f"identical: {len(upstream)} messages, {total} characters")
    return 0


if __name__ == "__main__":
    sys.exit(main())
