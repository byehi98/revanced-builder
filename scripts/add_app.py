#!/usr/bin/env python3
"""
Adds an app table to a patch author's config file in configs/<owner>-<repo>.toml.

Usage:
    python3 scripts/add_app.py <app_name> <patch_source> [package_name] [config_file]
"""

import glob
import json
import os
import re
import sys
import tomllib
import urllib.request


def normalize_name(name: str) -> str:
    return re.sub(r"[^a-zA-Z0-9]", "", name).lower()


def resolve_package(app_name: str, patch_source: str | None = None) -> str | None:
    app_clean = app_name.strip()
    # If app_name is already a package name (e.g. com.example.app)
    if "." in app_clean and re.match(r"^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$", app_clean):
        return app_clean

    norm_query = normalize_name(app_name)

    # 1. Search existing configs
    for file in sorted(glob.glob("configs/*.toml")):
        try:
            with open(file, "rb") as f:
                data = tomllib.load(f)
            for t_name, t in data.items():
                if not isinstance(t, dict):
                    continue
                norm_t = normalize_name(t_name)
                if norm_query == norm_t or norm_query in norm_t or norm_t in norm_query:
                    pkg = t.get("morphe-dlurl") or t.get("apkeep-dlurl") or t.get("pkg-name")
                    if pkg:
                        return pkg
        except Exception:
            pass

    # 2. Search patch source releases if provided
    if patch_source and "/" in patch_source:
        try:
            url = f"https://github.com/{patch_source}/releases/latest/download/patches-list.json"
            req = urllib.request.Request(url, headers={"User-Agent": "curl/7.68.0"})
            with urllib.request.urlopen(req, timeout=8) as resp:
                data = json.loads(resp.read())
            for p in data.get("patches", []):
                for pkg_info in (p.get("compatiblePackages") or []):
                    p_name = pkg_info.get("name") or ""
                    p_id = pkg_info.get("packageName") or ""
                    if p_name and p_id:
                        norm_p = normalize_name(p_name)
                        if norm_query == norm_p or norm_query in norm_p or norm_p in norm_query:
                            return p_id
        except Exception:
            pass

    # 3. Search Morphe archive
    try:
        url = "https://raw.githubusercontent.com/rushiforai/morphe-archive/refs/heads/main/docs/data.json"
        req = urllib.request.Request(url, headers={"User-Agent": "curl/7.68.0"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read())
        for a in data.get("apps", []):
            a_name = a.get("name") or ""
            a_pkg = a.get("packageName") or ""
            norm_a = normalize_name(a_name)
            if norm_query == norm_a or norm_query in norm_a or norm_a in norm_query:
                return a_pkg
    except Exception:
        pass

    return None


def main():
    if len(sys.argv) < 3:
        print("Usage: ./add-app.sh <app-name> <patch-source> [package-name] [config-file]")
        sys.exit(1)

    raw_app_name = sys.argv[1].strip()
    patch_source = sys.argv[2].strip()
    explicit_pkg = sys.argv[3].strip() if len(sys.argv) > 3 and sys.argv[3].strip() else None
    explicit_file = sys.argv[4].strip() if len(sys.argv) > 4 and sys.argv[4].strip() else None

    if "/" not in patch_source:
        print(f"Error: patch-source must be in 'owner/repo' format (got: '{patch_source}')")
        sys.exit(1)

    owner, repo = patch_source.split("/", 1)
    rv_brand = owner

    # Resolve package name
    pkg_name = explicit_pkg or resolve_package(raw_app_name, patch_source)
    if not pkg_name:
        print(f"Error: Could not resolve package name for '{raw_app_name}'.")
        print("Please provide the package name explicitly: ./add-app.sh <app-name> <patch-source> <package-name>")
        sys.exit(1)

    # Format app name for table: replace spaces with hyphens
    app_slug = re.sub(r"\s+", "-", raw_app_name)
    table_name = f"{app_slug}_{repo}"

    # Determine destination file
    target_file = explicit_file or f"configs/{owner}-{repo}.toml"
    os.makedirs(os.path.dirname(target_file), exist_ok=True)

    # Table TOML definition
    table_lines = [
        f"[{table_name}]",
        f"patches-source \t= \"{patch_source}\"",
        f"cli-source \t= \"MorpheApp/morphe-cli\"",
        f"rv-brand \t= \"{rv_brand}\"",
        f"morphe-dlurl \t= \"{pkg_name}\"",
        f"apkeep-dlurl \t= \"{pkg_name}\"",
    ]
    table_str = "\n".join(table_lines) + "\n"

    # Read existing file or create with header
    if os.path.exists(target_file):
        with open(target_file, "r", encoding="utf-8") as f:
            content = f.read()

        # Check if table already exists
        escaped_table = re.escape(table_name)
        pattern = rf"(^\[{escaped_table}\][\s\S]*?)(?=^\[|\Z)"
        if re.search(pattern, content, flags=re.M):
            print(f"Table [{table_name}] already exists in {target_file}. Updating it...")
            content = re.sub(pattern, table_str, content, count=1, flags=re.M)
        else:
            if not content.endswith("\n\n") and content.endswith("\n"):
                content += "\n"
            elif not content.endswith("\n"):
                content += "\n\n"
            content += table_str
    else:
        header = f"""# {patch_source}
#
# Patches bundle: https://github.com/{patch_source}
# CLI:            https://github.com/MorpheApp/morphe-cli

# every <source>-dlurl below is tried in DL_SRCS order
# (morphe, apkeep, apkcombo, apkmirror, apkpure, archive, direct, gplaydl, uptodown) and the next one
# is used when the current one cannot serve the required version.

"""
        content = header + table_str

    with open(target_file, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"[+] Successfully added table [{table_name}] to {target_file}")
    print(f"    Package: {pkg_name}")
    print(f"    Patch Source: {patch_source}")
    print(f"    CLI Source: MorpheApp/morphe-cli")
    print(f"    Brand: {rv_brand}")


if __name__ == "__main__":
    main()
