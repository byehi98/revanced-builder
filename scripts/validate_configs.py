#!/usr/bin/env python3
"""Validate the merged builder configuration before a build is dispatched.

The builder itself checks individual values while it walks the app tables, but
that happens after a 120-minute CI job has started.  This script repeats the
cheap checks up front so a typo fails a pull request instead of a scheduled
build.

Run it from the repository root::

    python3 scripts/validate_configs.py
    python3 scripts/validate_configs.py --root .

It uses the same include/merge semantics as ``scripts/generate_site.py`` and
``utils.sh``: ``app-configs`` adds every ``*.toml`` in a directory, ``imports``
adds files in order, and duplicate table names are fatal.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

from config_style import DL_KEYS, is_valid_table_name
from generate_site import load_config

SOURCE_RE = re.compile(
    r"^(?:GitLab:)?[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"
)
PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
VERSION_RE = re.compile(r"^(?:auto|latest|beta|experiment(?:al)?|[0-9][0-9A-Za-z._+-]*)$")

GLOBAL_KEYS = {
    "app-configs",
    "imports",
    "parallel-jobs",
    "compression-level",
    "remove-rv-integrations-checks",
    "enable-module-update",
    "dpi",
    "patches-source",
    "patches-sources",
    "patches-version",
    "cli-source",
    "cli-sources",
    "cli-version",
    "rv-brand",
}

APP_KEYS = {
    "app-name",
    "enabled",
    "build-mode",
    "version",
    "include-stock",
    "arch",
    "dpi",
    "module-prop-name",
    "pkg-name",
    "patcher-args",
    "excluded-patches",
    "included-patches",
    "exclusive-patches",
    "patches-source",
    "patches-sources",
    "patches-version",
    "cli-source",
    "cli-sources",
    "cli-version",
    "rv-brand",
    "morphe-helper-dlurl",
} | set(DL_KEYS)

PACKAGE_KEYS = {"pkg-name", "morphe-dlurl", "morphe-helper-dlurl", "aptoide-dlurl", "apkeep-dlurl", "gplaydl-dlurl"}
URL_KEYS = {
    "morphe-dlurl",
    "morphe-helper-dlurl",
    "aptoide-dlurl",
    "apkeep-dlurl",
    "apkcombo-dlurl",
    "apkmirror-dlurl",
    "apkpure-dlurl",
    "archive-dlurl",
    "direct-dlurl",
    "gplaydl-dlurl",
    "uptodown-dlurl",
}
DOWNLOAD_KEYS = URL_KEYS
TOGGLE_KEYS = {
    "enabled",
    "exclusive-patches",
    "remove-rv-integrations-checks",
    "enable-module-update",
}

BUILD_MODES = {"both", "apk", "module"}
INCLUDE_STOCK = {"disable", "merged", "split"}
ARCHES = {"both", "all", "arm64-v8a", "arm-v7a", "x86_64", "x86"}


class Problems:
    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, where: str, message: str) -> None:
        self.items.append(f"{where}: {message}")

    def extend(self, where: str, messages: list[str]) -> None:
        for message in messages:
            self.add(where, message)


def _is_toggle(value: Any) -> bool:
    return isinstance(value, bool) or (
        isinstance(value, str) and value.lower() in {"true", "false"}
    )


def _check_source(where: str, key: str, value: Any, problems: Problems) -> None:
    if not isinstance(value, str) or not SOURCE_RE.fullmatch(value):
        problems.add(where, f"{key} must be 'owner/repo' or 'GitLab:owner/repo', got {value!r}")


def _check_nonempty_string(where: str, key: str, value: Any, problems: Problems) -> bool:
    if not isinstance(value, str) or not value.strip():
        problems.add(where, f"{key} must be a non-empty string")
        return False
    return True


def check_settings(settings: dict[str, Any], root: Path, problems: Problems) -> None:
    unknown = sorted(set(settings) - GLOBAL_KEYS)
    if unknown:
        problems.add("config.toml", f"unknown global key(s): {', '.join(unknown)}")

    app_configs = settings.get("app-configs")
    if app_configs is not None:
        if not isinstance(app_configs, str) or not app_configs.strip():
            problems.add("config.toml", "app-configs must be a non-empty directory name")
        elif not (root / app_configs).is_dir():
            problems.add("config.toml", f"app-configs directory does not exist: {app_configs}")

    imports = settings.get("imports")
    if imports is not None:
        imported = [imports] if isinstance(imports, str) else imports
        if not isinstance(imported, list) or not all(
            isinstance(item, str) and item.strip() for item in imported
        ):
            problems.add("config.toml", "imports must be a string or a list of strings")
        else:
            for item in imported:
                if not (root / item).is_file():
                    problems.add("config.toml", f"import does not exist: {item}")

    if "parallel-jobs" in settings:
        value = settings["parallel-jobs"]
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            problems.add("config.toml", "parallel-jobs must be an integer >= 1")

    if "compression-level" in settings:
        value = settings["compression-level"]
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 9:
            problems.add("config.toml", "compression-level must be an integer between 0 and 9")

    for key in ("patches-source", "patches-sources", "cli-source", "cli-sources"):
        if key in settings:
            _check_source("config.toml", key, settings[key], problems)

    for key in ("remove-rv-integrations-checks", "enable-module-update"):
        if key in settings and not _is_toggle(settings[key]):
            problems.add("config.toml", f"{key} must be a boolean")

    for key in ("dpi", "patches-version", "cli-version", "rv-brand"):
        if key in settings:
            _check_nonempty_string("config.toml", key, settings[key], problems)


def check_app(name: str, data: dict[str, Any], problems: Problems) -> None:
    where = f"[{name}]"

    unknown = sorted(set(data) - APP_KEYS)
    if unknown:
        problems.add(where, f"unknown key(s): {', '.join(unknown)}")

    if not is_valid_table_name(name):
        problems.add(where, "table name must use letters, digits, '-' or '_' and start with a letter/digit")

    for key in ("patches-source", "patches-sources", "cli-source", "cli-sources"):
        if key in data:
            _check_source(where, key, data[key], problems)

    for key in (
        "app-name",
        "dpi",
        "module-prop-name",
        "patcher-args",
        "excluded-patches",
        "included-patches",
        "patches-version",
        "cli-version",
        "rv-brand",
    ):
        if key in data:
            _check_nonempty_string(where, key, data[key], problems)

    if "enabled" in data and not _is_toggle(data["enabled"]):
        problems.add(where, "enabled must be a boolean")
    if "exclusive-patches" in data and not _is_toggle(data["exclusive-patches"]):
        problems.add(where, "exclusive-patches must be a boolean")

    if "build-mode" in data and data["build-mode"] not in BUILD_MODES:
        problems.add(where, f"build-mode must be one of {', '.join(sorted(BUILD_MODES))}")
    if "include-stock" in data and data["include-stock"] not in INCLUDE_STOCK:
        problems.add(where, f"include-stock must be one of {', '.join(sorted(INCLUDE_STOCK))}")
    if "arch" in data and data["arch"] not in ARCHES:
        problems.add(where, f"arch must be one of {', '.join(sorted(ARCHES))}")
    if "version" in data:
        value = data["version"]
        if not isinstance(value, str) or not VERSION_RE.fullmatch(value):
            problems.add(
                where,
                "version must be 'auto', 'latest', 'beta', 'experiment', or a version number",
            )

    for key in sorted(PACKAGE_KEYS):
        if key in data:
            value = data[key]
            if not isinstance(value, str) or not PACKAGE_RE.fullmatch(value):
                problems.add(where, f"{key} must be an Android package name")
    for key in sorted(URL_KEYS - PACKAGE_KEYS):
        if key in data:
            value = data[key]
            if not isinstance(value, str) or not value.startswith(("https://", "http://")):
                problems.add(where, f"{key} must be an http(s) URL")

    if not any(key in data for key in DOWNLOAD_KEYS):
        problems.add(where, f"no download source is set (need one of: {', '.join(DL_KEYS)})")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate config.toml and configs/*.toml")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root (default: parent of scripts/)",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()
    problems = Problems()

    try:
        settings, apps = load_config(root)
    except SystemExit as exc:
        if exc.code not in (None, 0):
            return int(exc.code) if isinstance(exc.code, int) else 1
        raise

    check_settings(settings, root, problems)
    for name, data in apps.items():
        check_app(name, data, problems)

    if problems.items:
        print(f"config validation failed ({len(problems.items)} problem(s)):", file=sys.stderr)
        for problem in problems.items:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    enabled = sum(
        1
        for data in apps.values()
        if data.get("enabled", True) is not False
        and str(data.get("enabled", True)).lower() != "false"
    )
    print(
        f"config validation: {len(apps)} app table(s) ok, {enabled} enabled, "
        f"{len(apps) - enabled} disabled"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
