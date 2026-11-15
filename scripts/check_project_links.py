#!/usr/bin/env python3
"""Catch project links that still point at the upstream template repository.

Third-party links (``j-hc/zygisk-detach``, ``j-hc/rvmm-zygisk-mount`` and the
config generator) are intentional and are not checked here.  Only references to
the old project repository are rejected.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

UPSTREAM = "j-hc/revanced-magisk-module"
OLD_TEMPLATE = "template_name=revanced-magisk-module&template_owner=j-hc"
FILES = (
    "README.md",
    "CONFIG.md",
    "GEMINI.md",
    "build-termux.sh",
    "site/README.md",
    "site/index.html",
    "site/app.js",
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check project links for upstream leftovers")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root (default: parent of scripts/)",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()

    problems: list[str] = []
    checked = 0
    for relative in FILES:
        path = root / relative
        if not path.is_file():
            continue
        checked += 1
        for lineno, line in enumerate(
            path.read_text(encoding="utf-8", errors="replace").splitlines(), 1
        ):
            if UPSTREAM in line:
                problems.append(f"{relative}:{lineno}: links to {UPSTREAM}")
            elif OLD_TEMPLATE in line:
                problems.append(f"{relative}:{lineno}: uses the old repository template link")

    if problems:
        print("project link check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(f"project link check: {checked} file(s) ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
