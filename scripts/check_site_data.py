#!/usr/bin/env python3
"""Validate a generated ``site/data.json`` before it is published.

``site/data.json`` is a generated artifact and is no longer tracked.  CI and
``make check`` generate a fresh copy into a temporary directory and validate
that output, so a config change that breaks the catalogue fails before the
Pages deployment.

Examples::

    python3 scripts/check_site_data.py
    python3 scripts/check_site_data.py /tmp/catalog/data.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any

from generate_site import load_config

PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
OBTAINIUM_PREFIX = "https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/"
STATUSES = {"built", "failed", "unknown"}
BUILD_MODES = {"both", "apk", "module"}
OBTAINIUM_SOURCES = {"github", "html"}


class Problems:
    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, where: str, message: str) -> None:
        self.items.append(f"{where}: {message}")


def enabled(data: dict[str, Any]) -> bool:
    value = data.get("enabled", True)
    return value is not False and str(value).lower() != "false"


def parse_time(where: str, value: Any, problems: Problems, required: bool = False) -> None:
    if value is None and not required:
        return
    if not isinstance(value, str):
        problems.add(where, "must be an ISO-8601 timestamp")
        return
    try:
        dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        problems.add(where, f"invalid ISO-8601 timestamp: {value!r}")


def check_url(where: str, value: Any, problems: Problems) -> None:
    if not isinstance(value, str) or not value.startswith(("https://", "http://")):
        problems.add(where, "must be an http(s) URL")


def main(argv: list[str] | None = None) -> int:
    root_default = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Validate generated site/data.json")
    parser.add_argument(
        "data",
        nargs="?",
        type=Path,
        default=root_default / "site" / "data.json",
        help="generated data file (default: <root>/site/data.json)",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=root_default,
        help="repository root (default: parent of scripts/)",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()
    path = args.data.resolve()
    problems = Problems()

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        print(f"error: cannot read {path}: {exc}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as exc:
        print(f"error: {path} is not valid JSON: {exc}", file=sys.stderr)
        return 1

    if not isinstance(data, dict):
        print("error: data.json root must be an object", file=sys.stderr)
        return 1

    if data.get("schema") != 1:
        problems.add("$", f"schema must be 1, got {data.get('schema')!r}")
    if not isinstance(data.get("repo"), str) or not REPO_RE.fullmatch(data["repo"]):
        problems.add("$.repo", "must be owner/repo")
    for key in ("repo_url", "releases_url", "readme_url"):
        check_url(f"$.{key}", data.get(key), problems)
    parse_time("$.generated_at", data.get("generated_at"), problems, required=True)

    apps = data.get("apps")
    sources = data.get("sources")
    counts = data.get("counts")
    if not isinstance(apps, list):
        print("error: data.json has no apps array", file=sys.stderr)
        return 1
    if not isinstance(sources, list):
        problems.add("$.sources", "must be an array")
        sources = []
    if not isinstance(counts, dict):
        problems.add("$.counts", "must be an object")
        counts = {}

    tables: set[str] = set()
    packages: dict[str, str] = {}
    source_apps: dict[str, int] = {}
    source_built: dict[str, int] = {}
    built = 0

    for index, app in enumerate(apps):
        where = f"$.apps[{index}]"
        if not isinstance(app, dict):
            problems.add(where, "must be an object")
            continue

        table = app.get("table")
        if not isinstance(table, str) or not table.strip():
            problems.add(f"{where}.table", "must be a non-empty string")
        elif table in tables:
            problems.add(f"{where}.table", f"duplicate app table: {table}")
        else:
            tables.add(table)
            where = f"{where} ({table})"

        name = app.get("name")
        if not isinstance(name, str) or not name.strip():
            problems.add(f"{where}.name", "must be a non-empty string")

        package = app.get("package")
        if not isinstance(package, str) or not PACKAGE_RE.fullmatch(package):
            problems.add(f"{where}.package", "must be an Android package name")
        else:
            packages[package] = table

        source = app.get("source")
        if not isinstance(source, str) or not source.strip():
            problems.add(f"{where}.source", "must be a non-empty string")
        else:
            source_apps[source] = source_apps.get(source, 0) + 1
        check_url(f"{where}.source_url", app.get("source_url"), problems)

        status = app.get("status")
        if status not in STATUSES:
            problems.add(f"{where}.status", f"must be one of {', '.join(sorted(STATUSES))}")
        elif status == "built":
            built += 1
            if isinstance(source, str):
                source_built[source] = source_built.get(source, 0) + 1

        if app.get("build_mode") not in BUILD_MODES:
            problems.add(
                f"{where}.build_mode",
                f"must be one of {', '.join(sorted(BUILD_MODES))}",
            )
        if not isinstance(app.get("arch"), str) or not app["arch"]:
            problems.add(f"{where}.arch", "must be a non-empty string")

        parse_time(f"{where}.updated_at", app.get("updated_at"), problems)
        downloads = app.get("downloads")
        if isinstance(downloads, bool) or not isinstance(downloads, int) or downloads < 0:
            problems.add(f"{where}.downloads", "must be a non-negative integer")

        obtainium = app.get("obtainium")
        if not isinstance(obtainium, str) or not obtainium.startswith(OBTAINIUM_PREFIX):
            problems.add(f"{where}.obtainium", "must be an Obtainium redirect link")
        if app.get("obtainium_source") not in OBTAINIUM_SOURCES:
            problems.add(
                f"{where}.obtainium_source",
                f"must be one of {', '.join(sorted(OBTAINIUM_SOURCES))}",
            )

        icon = app.get("icon")
        if icon is not None:
            if not isinstance(icon, str) or not icon.startswith("icons/"):
                problems.add(f"{where}.icon", "must be a path under icons/")
            else:
                icon_path = (root / "site" / icon).resolve()
                try:
                    icon_path.relative_to((root / "site").resolve())
                except ValueError:
                    problems.add(f"{where}.icon", "must stay inside site/")
                else:
                    if not icon_path.is_file():
                        problems.add(f"{where}.icon", f"icon file is missing: {icon}")

        assets = app.get("assets")
        if not isinstance(assets, list):
            problems.add(f"{where}.assets", "must be an array")
            continue
        for asset_index, asset in enumerate(assets):
            asset_where = f"{where}.assets[{asset_index}]"
            if not isinstance(asset, dict):
                problems.add(asset_where, "must be an object")
                continue
            if not isinstance(asset.get("name"), str) or not asset["name"]:
                problems.add(f"{asset_where}.name", "must be a non-empty string")
            check_url(f"{asset_where}.url", asset.get("url"), problems)

    if not apps:
        problems.add("$.apps", "must not be empty")

    for key, actual in (("apps", len(apps)), ("built", built), ("sources", len(sources))):
        expected = counts.get(key)
        if isinstance(expected, bool) or not isinstance(expected, int) or expected != actual:
            problems.add(f"$.counts.{key}", f"must be {actual}, got {expected!r}")

    seen_sources: set[str] = set()
    for index, item in enumerate(sources):
        where = f"$.sources[{index}]"
        if not isinstance(item, dict):
            problems.add(where, "must be an object")
            continue
        source = item.get("source")
        if not isinstance(source, str) or not source.strip():
            problems.add(f"{where}.source", "must be a non-empty string")
            continue
        if source in seen_sources:
            problems.add(f"{where}.source", f"duplicate source: {source}")
        seen_sources.add(source)
        check_url(f"{where}.url", item.get("url"), problems)
        if item.get("apps") != source_apps.get(source):
            problems.add(
                f"{where}.apps",
                f"must be {source_apps.get(source, 0)}, got {item.get('apps')!r}",
            )
        if item.get("built") != source_built.get(source, 0):
            problems.add(
                f"{where}.built",
                f"must be {source_built.get(source, 0)}, got {item.get('built')!r}",
            )

    missing_sources = sorted(set(source_apps) - seen_sources)
    extra_sources = sorted(seen_sources - set(source_apps))
    if missing_sources:
        problems.add("$.sources", f"missing source(s): {', '.join(missing_sources)}")
    if extra_sources:
        problems.add("$.sources", f"unknown source(s): {', '.join(extra_sources)}")

    try:
        _, config_apps = load_config(root)
    except SystemExit:
        return 1
    expected_tables = {name for name, value in config_apps.items() if enabled(value)}
    missing = sorted(expected_tables - tables)
    extra = sorted(tables - expected_tables)
    if missing:
        problems.add("$.apps", f"missing enabled app(s): {', '.join(missing)}")
    if extra:
        problems.add("$.apps", f"app(s) not enabled in config: {', '.join(extra)}")

    if problems.items:
        print(f"site data validation failed ({len(problems.items)} problem(s)):", file=sys.stderr)
        for problem in problems.items:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(
        f"site data validation: {len(apps)} apps ({built} built), "
        f"{len(sources)} sources, {len(packages)} unique packages — ok"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
