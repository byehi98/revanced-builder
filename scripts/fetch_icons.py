#!/usr/bin/env python3
"""Fetch a real launcher icon for every app in the Obtainium catalogue.

The icon for each Android package is written to ``site/icons/<package>.png``.
Two sources are used, in the same order as ``hxreborn/morphe-patches``:

1. the app's Google Play listing icon at 96x96, already cut to a circle;
2. if the app is not on Play (or the patched package ID does not exist there),
   the launcher icon is extracted from the built APK using HTTP range requests.

Icons are committed to the repository, so the deploy workflow only needs to run
this script when an app was added.  Run it manually with::

    python3 scripts/fetch_icons.py

Use ``--force`` to refresh every icon and ``--jobs N`` to change concurrency.
Extracting an APK icon requires ImageMagick (``magick`` or ``convert``).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from apk_icons import IconResolver, RemoteZip, render_to_png  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DATA_FILE = ROOT / "site" / "data.json"
ICON_DIR = ROOT / "site" / "icons"
SOURCES_FILE = ICON_DIR / "sources.json"
PLAY_URL = "https://play.google.com/store/apps/details?id={}&hl=en&gl=US"
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)

# Patched apps use a different package ID from the upstream app.  The Play
# listing of the original package still shows the launcher icon users expect.
PLAY_OVERRIDES = {
    "app.morphe.android.youtube": "com.google.android.youtube",
    "app.morphe.android.apps.youtube.music": "com.google.android.apps.youtube.music",
    "app.morphe.android.apps.photos": "com.google.android.apps.photos",
    "com.easybrain.arrow.puzzle.game.morphe": "com.easybrain.arrow.puzzle.game",
    "org.ungoogled.android.apps.maps": "com.google.android.apps.maps",
}


def load_catalog() -> dict[str, dict[str, Any]]:
    """Return package -> newest APK asset, preferring the most recent build."""

    try:
        data = json.loads(DATA_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        sys.exit(f"error: catalogue not found: {DATA_FILE}\nrun scripts/generate_site.py first")

    packages: dict[str, dict[str, Any]] = {}
    for app in data.get("apps") or []:
        package = app.get("package")
        if not package:
            continue
        for asset in app.get("assets") or []:
            if asset.get("kind") != "apk" or not asset.get("url") or not asset.get("size"):
                continue
            updated = str(asset.get("updated_at") or "")
            current = packages.get(package)
            if current is None or updated > current["updated"]:
                packages[package] = {
                    "updated": updated,
                    "app": app.get("name") or package,
                    "asset": asset,
                }
    return packages


def play_icon_url(package: str) -> str | None:
    request = urllib.request.Request(
        PLAY_URL.format(urllib.parse.quote(package, safe="._-")),
        headers={"User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            page = response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError, OSError):
        return None
    match = re.search(r'"image":"(https://play-lh\.googleusercontent\.com/[^"]+)"', page)
    return match.group(1) if match else None


def download(url: str, destination: Path) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    if not data:
        raise RuntimeError("empty response")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return data


def fetch_from_play(package: str, destination: Path) -> dict[str, str]:
    lookup = PLAY_OVERRIDES.get(package, package)
    icon = play_icon_url(lookup)
    if not icon:
        raise RuntimeError(f"no Play listing icon for {lookup}")
    temporary = destination.with_name(destination.name + ".tmp")
    try:
        data = download(icon + "=s96-cc", temporary)
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("Play icon was not a PNG")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return {
        "file": destination.name,
        "source": "google-play",
        "play_package": lookup,
    }


def fetch_from_apk(package: str, entry: dict[str, Any], destination: Path) -> dict[str, str]:
    asset = entry["asset"]
    resolver = IconResolver(RemoteZip(asset["url"], int(asset["size"])))
    candidates = resolver.icon_candidates()
    if not candidates:
        raise RuntimeError("no launcher icon found in APK")

    temporary = destination.with_name(destination.name + ".tmp")
    errors: list[str] = []
    for candidate in candidates[:8]:
        try:
            render_to_png(candidate, temporary, 96, resolver._xml)
            if _is_blank(temporary):
                raise RuntimeError("rendered a blank icon")
            temporary.replace(destination)
            return {
                "file": destination.name,
                "source": "apk",
                "app": entry["app"],
                "asset": asset.get("name") or "",
                "drawable": candidate.name,
            }
        except Exception as exc:  # try the next candidate (e.g. monochrome layer)
            errors.append(f"{candidate.name}: {exc}")
            temporary.unlink(missing_ok=True)
    raise RuntimeError("; ".join(errors[-3:]))


def _is_blank(path: Path) -> bool:
    magick = shutil.which("magick") or shutil.which("convert")
    if not magick:
        return False
    result = subprocess.run(
        [magick, str(path), "-format", "%[fx:mean.a]", "info:"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False
    try:
        return float(result.stdout.strip()) < 0.005
    except ValueError:
        return False


def write_sources(entries: dict[str, dict[str, str]]) -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    SOURCES_FILE.write_text(
        json.dumps(dict(sorted(entries.items())), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def annotate_catalog() -> None:
    """Add ``icon`` paths to data.json without re-running the GitHub queries."""

    try:
        data = json.loads(DATA_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return
    changed = False
    for app in data.get("apps") or []:
        package = app.get("package")
        icon = ICON_DIR / f"{package}.png" if package else None
        value = f"icons/{package}.png" if icon and icon.is_file() else None
        if value:
            if app.get("icon") != value:
                app["icon"] = value
                changed = True
        elif "icon" in app:
            del app["icon"]
            changed = True
    if changed:
        DATA_FILE.write_text(
            json.dumps(data, ensure_ascii=False, indent=1) + "\n",
            encoding="utf-8",
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="refresh icons that already exist")
    parser.add_argument("--jobs", type=int, default=8, help="parallel network requests (default: 8)")
    parser.add_argument(
        "--no-apk-fallback",
        action="store_true",
        help="only use Google Play and leave apps without a listing without an icon",
    )
    args = parser.parse_args()

    packages = load_catalog()
    ICON_DIR.mkdir(parents=True, exist_ok=True)

    sources: dict[str, dict[str, str]] = {}
    if SOURCES_FILE.is_file():
        try:
            sources = json.loads(SOURCES_FILE.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            sources = {}

    pending = [
        package
        for package in sorted(packages)
        if args.force or not (ICON_DIR / f"{package}.png").is_file()
    ]
    print(f"{len(packages)} packages, {len(pending)} icon(s) to fetch")

    failures: dict[str, str] = {}

    def try_play(package: str) -> tuple[str, dict[str, str] | None, str | None]:
        destination = ICON_DIR / f"{package}.png"
        try:
            return package, fetch_from_play(package, destination), None
        except Exception as exc:
            return package, None, str(exc)

    if pending:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            for package, result, error in pool.map(try_play, pending):
                if result:
                    sources[package] = result
                    print(f"  play  {package}")
                else:
                    failures[package] = error or "unknown error"

    if failures and not args.no_apk_fallback:
        fallback = sorted(failures)
        print(f"{len(fallback)} Play miss(es), trying APK extraction")

        def try_apk(package: str) -> tuple[str, dict[str, str] | None, str | None]:
            destination = ICON_DIR / f"{package}.png"
            try:
                return package, fetch_from_apk(package, packages[package], destination), None
            except Exception as exc:
                return package, None, str(exc)

        with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(fallback))) as pool:
            for package, result, error in pool.map(try_apk, fallback):
                if result:
                    sources[package] = result
                    failures.pop(package, None)
                    print(f"  apk   {package} ({result.get('drawable', '')})")
                else:
                    failures[package] = error or "unknown error"

    # Drop stale records for packages that no longer exist, and record icons
    # that were skipped because they were already present.
    for package in packages:
        icon = ICON_DIR / f"{package}.png"
        if package not in sources and icon.is_file():
            sources[package] = {"file": icon.name, "source": "committed"}
    sources = {package: entry for package, entry in sources.items() if package in packages}
    write_sources(sources)
    annotate_catalog()

    missing = sorted(package for package in packages if not (ICON_DIR / f"{package}.png").is_file())
    print(f"wrote {len(packages) - len(missing)}/{len(packages)} icons to {ICON_DIR.relative_to(ROOT)}")
    for package in missing:
        print(f"  missing {package}: {failures.get(package, 'not fetched')}", file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
