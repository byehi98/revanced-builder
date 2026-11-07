#!/usr/bin/env python3
"""Generate the static Obtainium catalogue served by the project website.

The site is intentionally dependency-free: a single ``data.json`` is written
next to ``index.html`` and rendered client-side.  This script collects the data
from three places, newest information first:

* ``config.toml`` + ``configs/*.toml`` -- which apps exist, their patches source
  and the filename prefix used for their release assets;
* the generated README build-status table -- package IDs, status and the exact
  Obtainium links that were published there;
* the GitHub releases API -- the newest APK/module asset for every app, with
  size, download count and release/date metadata.

Run it locally with::

    python3 scripts/generate_site.py

or, without network access::

    python3 scripts/generate_site.py --offline

The GitHub token is read from ``--token``, ``GH_TOKEN`` or ``GITHUB_TOKEN``.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
BUILD_STATUS_START = "<!-- BUILD_STATUS_START -->"
BUILD_STATUS_END = "<!-- BUILD_STATUS_END -->"

ARCH_ORDER = ("all", "arm64-v8a", "arm-v7a", "x86_64", "x86")
KIND_ORDER = {"apk": 0, "module": 1}
PKG_KEYS = ("pkg-name", "morphe-dlurl", "aptoide-dlurl", "apkeep-dlurl", "gplaydl-dlurl")
PKG_URL_KEYS = ("apkpure-dlurl", "apkcombo-dlurl")


# --------------------------------------------------------------------------- #
# config
# --------------------------------------------------------------------------- #


def read_toml(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as fh:
            return tomllib.load(fh)
    except FileNotFoundError:
        sys.exit(f"error: config not found: {path}")
    except (OSError, tomllib.TOMLDecodeError) as exc:
        sys.exit(f"error: cannot read {path}: {exc}")


def load_config(root: Path) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    """Return (global settings, app tables) with includes expanded like utils.sh."""

    main = read_toml(root / "config.toml")
    apps: dict[str, dict[str, Any]] = {}

    def visit(path: Path, seen: set[Path]) -> None:
        cfg = read_toml(path)
        includes: list[Path] = []

        app_configs = cfg.get("app-configs")
        if isinstance(app_configs, str):
            directory = path.parent / app_configs
            if directory.is_dir():
                includes.extend(sorted(directory.glob("*.toml")))
            else:
                print(f"warning: app-configs directory not found: {directory}", file=sys.stderr)

        imports = cfg.get("imports")
        if isinstance(imports, str):
            imports = [imports]
        if isinstance(imports, list):
            includes.extend(path.parent / str(item) for item in imports)

        for include in includes:
            include = include.resolve()
            if include in seen or not include.is_file():
                continue
            seen.add(include)
            visit(include, seen)

        for name, value in cfg.items():
            if name in ("app-configs", "imports"):
                continue
            if isinstance(value, dict):
                if name in apps:
                    sys.exit(f"error: duplicate app table '{name}' (seen again in {path})")
                apps[name] = value

    visit((root / "config.toml").resolve(), {(root / "config.toml").resolve()})
    return main, apps


def slug(value: str) -> str:
    return value.lower().replace(" ", "-")


def looks_like_package(value: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+", value))


def derive_package_id(data: dict[str, Any]) -> str:
    """Best-effort package ID from the download URLs in an app table."""

    for key in PKG_KEYS:
        value = str(data.get(key, "")).strip()
        if looks_like_package(value):
            return value

    for key in PKG_URL_KEYS:
        value = str(data.get(key, "")).strip()
        if not value:
            continue
        candidate = urllib.parse.urlparse(value).path.strip("/").split("/")[-1]
        if looks_like_package(candidate):
            return candidate

    direct = str(data.get("direct-dlurl", "")).strip()
    if direct:
        name = urllib.parse.urlparse(direct).path.rsplit("/", 1)[-1]
        match = re.match(r"([A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+)-", name)
        if match:
            return match.group(1)

    return ""


def source_url(source: str) -> str:
    if source.startswith("GitLab:"):
        return "https://gitlab.com/" + source[len("GitLab:") :]
    return "https://github.com/" + source


def source_author(source: str) -> str:
    if source.startswith("GitLab:"):
        source = source[len("GitLab:") :]
    return source.split("/", 1)[0].lower()


def version_from_bundle(bundle: str | None) -> str | None:
    if not bundle:
        return None
    match = re.match(r"patches-(.+)\.(?:mpp|rvp|jar)$", bundle)
    return match.group(1) if match else bundle


# --------------------------------------------------------------------------- #
# README build-status table
# --------------------------------------------------------------------------- #


def decode_obtainium(url: str) -> dict[str, Any] | None:
    marker = "obtainium://app/"
    if marker not in url:
        return None
    raw = urllib.parse.unquote(url.split(marker, 1)[1])
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def parse_readme(path: Path) -> dict[str, dict[str, Any]]:
    """Parse the machine-generated table between the build-status markers."""

    if not path.is_file():
        return {}

    entries: dict[str, dict[str, Any]] = {}
    source: str | None = None
    bundle: str | None = None
    in_status = False

    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()

        if line.startswith(BUILD_STATUS_START):
            in_status = True
            continue
        if line.startswith(BUILD_STATUS_END):
            break
        if not in_status:
            continue

        heading = re.match(r"^####\s+`([^`]+)`(?:\s*·\s*`([^`]+)`)?", line)
        if heading:
            source = heading.group(1)
            bundle = heading.group(2)
            continue

        if not line.startswith("|") or line.startswith("| :---"):
            continue
        parts = [part.strip() for part in line.split("|")]
        if len(parts) < 4:
            continue

        cell = parts[1]
        name_match = re.match(r"^`([^`]+)`\s*(.*)$", cell)
        if not name_match:
            continue
        table = name_match.group(1)
        rest = name_match.group(2)

        status_text = parts[2]
        status = "failed" if "❌" in status_text else "built" if "✅" in status_text else "unknown"

        obtainium_url = None
        obtainium = None
        for candidate in re.findall(r"\((https?://[^)]+)\)", parts[3]):
            decoded = decode_obtainium(candidate)
            if decoded:
                obtainium_url = candidate
                obtainium = decoded
                break

        links = [
            {"label": label, "url": url}
            for label, url in re.findall(r"\[([^\]]+)\]\((https?://[^)]+)\)", rest)
        ]

        entries[table] = {
            "source": source,
            "bundle": bundle,
            "status": status,
            "obtainium_url": obtainium_url,
            "obtainium": obtainium,
            "links": links,
        }

    return entries


def parse_build_md(text: str) -> dict[str, str]:
    """Map a patches-source author to the patch bundle version from build.md."""

    versions: dict[str, str] = {}
    for line in text.splitlines():
        match = re.match(r"^Patches:\s*([^/\s]+)/patches-(.+)\.(?:mpp|rvp|jar)\s*$", line.strip())
        if match:
            versions[match.group(1).lower()] = match.group(2)
    return versions


# --------------------------------------------------------------------------- #
# GitHub
# --------------------------------------------------------------------------- #


def request_text(url: str, token: str | None) -> str:
    headers = {"User-Agent": "rvb-obtainium-site/1.0", "Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=45) as response:
        return response.read().decode("utf-8", "replace")


def request_json(url: str, token: str | None) -> Any:
    return json.loads(request_text(url, token))


def fetch_releases(repo: str, token: str | None, max_pages: int) -> list[dict[str, Any]]:
    releases: list[dict[str, Any]] = []
    for page in range(1, max_pages + 1):
        url = f"https://api.github.com/repos/{repo}/releases?per_page=100&page={page}"
        try:
            batch = request_json(url, token)
        except urllib.error.HTTPError as exc:
            print(f"warning: could not read releases page {page}: HTTP {exc.code}", file=sys.stderr)
            if exc.code == 403:
                print("warning: GitHub rate limit hit; try --token or --offline", file=sys.stderr)
            break
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            print(f"warning: could not read releases page {page}: {exc}", file=sys.stderr)
            break
        if not isinstance(batch, list) or not batch:
            break
        releases.extend(batch)
        if len(batch) < 100:
            break
    return releases


def fetch_patch_versions(repo: str, token: str | None) -> dict[str, str]:
    url = f"https://raw.githubusercontent.com/{repo}/update/build.md"
    try:
        return parse_build_md(request_text(url, token))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        print(f"warning: could not read update/build.md: {exc}", file=sys.stderr)
        return {}


# --------------------------------------------------------------------------- #
# assets
# --------------------------------------------------------------------------- #


def split_filename(name: str, prefix: str) -> dict[str, Any] | None:
    """Return kind/version/arch for an asset belonging to ``prefix``."""

    lower = name.lower()
    if not lower.startswith(prefix + "-"):
        return None
    extension = os.path.splitext(lower)[1]
    if extension not in (".apk", ".zip"):
        return None

    rest = name[len(prefix) :]
    if lower.endswith(".zip"):
        kind = "module"
        if rest.startswith("-module-v"):
            rest = rest[len("-module-v") :]
        elif rest.startswith("-v"):
            rest = rest[len("-v") :]
        else:
            return None
    else:
        kind = "apk"
        if rest.startswith("-v"):
            rest = rest[len("-v") :]
        else:
            return None

    stem = rest[: -len(extension)]
    arch = None
    version = stem
    for candidate in ARCH_ORDER:
        suffix = "-" + candidate
        if stem.endswith(suffix):
            arch = candidate
            version = stem[: -len(suffix)]
            break

    return {"kind": kind, "version": version or None, "arch": arch}


def asset_preference(asset: dict[str, Any]) -> tuple[int, int, int]:
    return (
        KIND_ORDER.get(asset.get("kind", ""), 9),
        ARCH_ORDER.index(asset["arch"]) if asset.get("arch") in ARCH_ORDER else len(ARCH_ORDER),
        0 if asset.get("version") else 1,
    )


def asset_from_api(asset: dict[str, Any], release: dict[str, Any], info: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": asset.get("name", ""),
        "url": asset.get("browser_download_url", ""),
        "kind": info["kind"],
        "version": info["version"],
        "arch": info["arch"],
        "size": asset.get("size"),
        "downloads": asset.get("download_count"),
        "release": release.get("tag_name"),
        "release_url": release.get("html_url"),
        "updated_at": asset.get("updated_at") or release.get("published_at") or release.get("created_at"),
    }


def asset_from_link(link: dict[str, str], info: dict[str, Any]) -> dict[str, Any]:
    name = link["url"].rsplit("/", 1)[-1].split("?", 1)[0]
    match = re.search(r"/releases/download/([^/]+)/", link["url"])
    return {
        "name": name,
        "url": link["url"],
        "kind": info["kind"],
        "version": info["version"],
        "arch": info["arch"],
        "size": None,
        "downloads": None,
        "release": match.group(1) if match else None,
        "release_url": None,
        "updated_at": None,
    }


def merge_assets(
    app: dict[str, Any],
    prefix: str,
    api_assets: list[dict[str, Any]],
    readme_entry: dict[str, Any] | None,
) -> None:
    """Prefer live release metadata, falling back to the README links."""

    assets = api_assets
    if not assets and readme_entry:
        for link in readme_entry.get("links") or []:
            name = link["url"].rsplit("/", 1)[-1].split("?", 1)[0]
            info = split_filename(name, prefix)
            if not info:
                extension = os.path.splitext(name.lower())[1]
                if extension not in (".apk", ".zip"):
                    continue
                info = {
                    "kind": "module" if extension == ".zip" else "apk",
                    "version": None,
                    "arch": None,
                }
            assets.append(asset_from_link(link, info))

    # de-duplicate by URL, keeping the first (newest) occurrence
    unique: dict[str, dict[str, Any]] = {}
    for asset in assets:
        url = asset.get("url")
        if url and url not in unique:
            unique[url] = asset
    app["assets"] = sorted(unique.values(), key=asset_preference)

    if app["assets"]:
        primary = app["assets"][0]
        app["version"] = primary.get("version")
        app["updated_at"] = max(
            (asset.get("updated_at") or "" for asset in app["assets"]), default=""
        ) or None
        app["downloads"] = sum(asset.get("downloads") or 0 for asset in app["assets"])


# --------------------------------------------------------------------------- #
# obtainium
# --------------------------------------------------------------------------- #


def obtainium_link(package: str, repo: str, owner: str, app_name: str, prefix: str) -> str:
    additional_settings = json.dumps(
        {"apkFilterRegEx": prefix, "autoApkFilterByArch": True},
        separators=(",", ":"),
    )
    payload = json.dumps(
        {
            "id": package,
            "url": f"https://github.com/{repo}",
            "author": owner,
            "name": app_name,
            "additionalSettings": additional_settings,
        },
        separators=(",", ":"),
    )
    return "https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/" + urllib.parse.quote(payload)


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #


def detect_repo(explicit: str | None) -> str:
    if explicit:
        return explicit.strip().strip("/")

    env_repo = os.environ.get("GITHUB_REPOSITORY")
    if env_repo:
        return env_repo.strip().strip("/")

    try:
        remote = subprocess.check_output(
            ["git", "config", "--get", "remote.origin.url"],
            cwd=ROOT,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        remote = ""

    match = re.search(r"github\.com[^:/]*[:/]([^/]+/[^/]+?)(?:\.git)?$", remote)
    if match:
        return match.group(1)
    return "byehi98/revanced-builder"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate site/data.json for the Obtainium catalogue")
    parser.add_argument("--repo", help="GitHub repository (owner/name)")
    parser.add_argument("--root", type=Path, default=ROOT, help="Repository root")
    parser.add_argument("--output", type=Path, help="Output JSON path (default: <root>/site/data.json)")
    parser.add_argument("--token", help="GitHub token (default: GH_TOKEN or GITHUB_TOKEN)")
    parser.add_argument("--offline", action="store_true", help="Do not call the GitHub API")
    parser.add_argument("--max-pages", type=int, default=20, help="Maximum release pages to read")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.root.resolve()
    output = (args.output or (root / "site/data.json")).resolve()
    repo = detect_repo(args.repo)
    owner = repo.split("/", 1)[0]
    token = args.token or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")

    settings, config_apps = load_config(root)
    readme_entries = parse_readme(root / "README.md")
    patch_versions: dict[str, str] = {}
    releases: list[dict[str, Any]] = []

    if not args.offline:
        patch_versions = fetch_patch_versions(repo, token)
        releases = fetch_releases(repo, token, args.max_pages)

    default_source = (
        settings.get("patches-source")
        or settings.get("patches-sources")
        or "ReVanced/revanced-patches"
    )
    default_brand = settings.get("rv-brand", "ReVanced")

    entries: list[dict[str, Any]] = []
    by_prefix: dict[str, dict[str, Any]] = {}
    prefixes = sorted(
        (
            (
                f"{slug(str(data.get('app-name', table)))}-{slug(str(data.get('rv-brand', default_brand)))}",
                table,
                data,
            )
            for table, data in config_apps.items()
        ),
        key=lambda item: len(item[0]),
        reverse=True,
    )

    for prefix, table, data in prefixes:
        enabled = data.get("enabled", True)
        if enabled is False or str(enabled).lower() == "false":
            continue

        readme = readme_entries.get(table) or {}
        source = (
            data.get("patches-source")
            or data.get("patches-sources")
            or default_source
        )
        app_name = str(data.get("app-name", table))
        brand = str(data.get("rv-brand", default_brand))
        package = (
            (readme.get("obtainium") or {}).get("id")
            or derive_package_id(data)
            or ""
        )
        bundle = (readme.get("bundle") or "")
        bundle_version = version_from_bundle(bundle)
        patch_version = patch_versions.get(source_author(source)) or bundle_version

        entry = {
            "table": table,
            "name": app_name,
            "brand": brand,
            "package": package,
            "source": source,
            "source_url": source_url(source),
            "patch_version": patch_version,
            "patch_bundle": bundle or None,
            "status": readme.get("status") or "unknown",
            "build_mode": data.get("build-mode", "apk"),
            "arch": data.get("arch", "all"),
            "version": None,
            "updated_at": None,
            "downloads": 0,
            "assets": [],
            "obtainium": obtainium_link(package, repo, owner, app_name, prefix),
            "_prefix": prefix,
            "_readme": readme,
        }
        entries.append(entry)
        by_prefix[prefix] = entry

    # The README knows about apps that are currently disabled/removed; keep the
    # site to the tables that are actually in the config.
    prefix_list = list(by_prefix)

    api_assets: dict[str, list[dict[str, Any]]] = {entry["table"]: [] for entry in entries}
    seen_variants: set[tuple[str, str, str]] = set()

    for release in releases:
        for raw_asset in release.get("assets") or []:
            name = str(raw_asset.get("name", ""))
            matched = None
            for prefix in prefix_list:
                if name.lower().startswith(prefix + "-"):
                    matched = prefix
                    break
            if not matched:
                continue
            info = split_filename(name, matched)
            if not info:
                continue
            variant = (matched, info["kind"], info["arch"] or "")
            if variant in seen_variants:
                continue
            seen_variants.add(variant)
            app = by_prefix[matched]
            api_assets[app["table"]].append(asset_from_api(raw_asset, release, info))

    for entry in entries:
        merge_assets(entry, entry["_prefix"], api_assets.get(entry["table"], []), entry.get("_readme"))
        if entry["assets"]:
            entry["status"] = "built"
        entry.pop("_prefix", None)
        entry.pop("_readme", None)

    apps = sorted(entries, key=lambda app: app["name"].lower())

    sources: dict[str, dict[str, Any]] = {}
    for app in apps:
        item = sources.setdefault(
            app["source"],
            {
                "source": app["source"],
                "url": app["source_url"],
                "patch_version": app["patch_version"],
                "apps": 0,
                "built": 0,
            },
        )
        item["apps"] += 1
        if app["status"] == "built":
            item["built"] += 1
        if not item.get("patch_version") and app["patch_version"]:
            item["patch_version"] = app["patch_version"]

    latest_release = releases[0].get("tag_name") if releases else None
    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()

    data = {
        "schema": 1,
        "generated_at": generated_at,
        "repo": repo,
        "repo_url": f"https://github.com/{repo}",
        "releases_url": f"https://github.com/{repo}/releases",
        "readme_url": f"https://github.com/{repo}#build-status",
        "latest_release": latest_release,
        "counts": {
            "apps": len(apps),
            "built": sum(1 for app in apps if app["status"] == "built"),
            "sources": len(sources),
        },
        "sources": sorted(sources.values(), key=lambda item: item["source"].lower()),
        "apps": apps,
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
        fh.write("\n")

    built = data["counts"]["built"]
    print(
        f"wrote {output} — {len(apps)} apps ({built} built), "
        f"{len(sources)} sources, {len(releases)} releases scanned"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
