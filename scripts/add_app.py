#!/usr/bin/env python3
"""Add or update an app table in ``configs/*.toml``.

The generated config follows the repository-wide style enforced by
``scripts/config_style.py``: canonical header, key order, aligned ``=`` and
plain app table names (``[TradingView]``, not ``[TradingView_morphe-patches]``).

Usage:
    python3 scripts/add_app.py <app-name> <patch-source> [package-name] [config-file]
    python3 scripts/add_app.py --app TradingView --source hxreborn/morphe-patches --json
"""

from __future__ import annotations

import argparse
import difflib
import glob
import json
import re
import sys
import tomllib
import urllib.error
import urllib.request
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from config_style import (
    Table,
    header_extras,
    header_source_and_cli,
    is_valid_table_name,
    merge_table,
    parse_document,
    quote,
    render_document,
    render_header,
    render_table,
    sort_table,
)

DEFAULT_CLI = "MorpheApp/morphe-cli"
ARCHIVE_URL = (
    "https://raw.githubusercontent.com/rushiforai/morphe-archive/refs/heads/main/docs/data.json"
)
PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
SOURCE_PART_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
BRAND_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# Fallbacks for a brand-new config file, where the file has no brand yet.
# Existing files always keep their own dominant brand.
BRAND_ALIASES = {
    "Alastor-Kaneki/Morphe-Patches": "Kaneki",
    "BholeyKaBhakt/android-patches-xtra": "xtra",
    "BlazeFTL/FTL-Patches": "FTL",
    "MorpheApp/morphe-patches": "morphe",
    "SysAdminDoc/HushTelegram": "hush",
    "arandomhooman/hoomans-morphe-patches": "hoomans",
    "byehi98/okish-morphe-patches": "okish",
    "jkennethcarino/adobo": "adobo",
    "kiraio-moe/Lain-Patches": "lain",
    "prathxmOp/prathxm-patches": "Prathxm",
    "sushruth/imgur-patches": "imgur",
}
CLI_ALIASES = {
    "Aunali321/ReVancedExperiments": "ReVanced/revanced-cli",
}

EXIT_ERROR = 1
EXIT_AMBIGUOUS = 2


class Failure(Exception):
    def __init__(self, message: str, code: int = EXIT_ERROR):
        super().__init__(message)
        self.code = code


def warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def normalize_name(name: str) -> str:
    return re.sub(r"[^a-zA-Z0-9]", "", name).lower()


def slugify(value: str) -> str:
    slug = re.sub(r"\s+", "-", value.strip())
    slug = re.sub(r"[^A-Za-z0-9_-]+", "", slug)
    slug = re.sub(r"-{2,}", "-", slug).strip("-_")
    return slug


def validate_app_name(name: str) -> str:
    name = name.strip()
    if not name:
        raise Failure("app name must not be empty")
    if len(name) > 80:
        raise Failure(f"app name is too long ({len(name)} > 80 characters)")
    if any(ord(char) < 32 or ord(char) == 127 for char in name):
        raise Failure("app name must not contain newlines or control characters")
    if any(char in name for char in '[]"\\/'):
        raise Failure("app name must not contain [ ] \" \\ or /")
    return name


def validate_package(package: str) -> str:
    package = package.strip()
    if not PACKAGE_RE.fullmatch(package):
        raise Failure(
            f"invalid Android package name '{package}' "
            "(expected something like com.example.app)"
        )
    return package


def validate_source(source: str) -> tuple[str, str]:
    source = source.strip()
    if source.endswith(".git"):
        source = source[:-4]
    parts = source.split("/")
    if len(parts) != 2 or not all(SOURCE_PART_RE.fullmatch(part) for part in parts):
        raise Failure(
            f"patch source must be in 'owner/repo' form (got '{source}')"
        )
    return parts[0], parts[1]


def validate_table_name(name: str) -> str:
    name = name.strip()
    if not is_valid_table_name(name):
        raise Failure(
            f"invalid table name '{name}' "
            "(allowed: letters, digits, '-' and '_'; must start with a letter or digit)"
        )
    if len(name) > 80:
        raise Failure(f"table name is too long ({len(name)} > 80 characters)")
    return name


def validate_brand(brand: str) -> str:
    brand = brand.strip()
    if not BRAND_RE.fullmatch(brand):
        raise Failure(
            f"invalid rv-brand '{brand}' "
            "(allowed: letters, digits, '.', '-' and '_')"
        )
    return brand


def fetch_json(url: str, timeout: int = 10) -> object:
    request = urllib.request.Request(url, headers={"User-Agent": "revanced-builder"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


@dataclass
class Resolved:
    package: str
    name: str | None = None
    table_hint: str | None = None
    origin: str = ""


@dataclass
class BundleIndex:
    name_to_packages: dict[str, set[str]] = field(default_factory=dict)
    package_to_name: dict[str, str] = field(default_factory=dict)
    packages: set[str] = field(default_factory=set)
    error: str | None = None

    def add(self, name: str, package: str) -> None:
        if not name or not package:
            return
        normalized = normalize_name(name)
        if not normalized:
            return
        self.name_to_packages.setdefault(normalized, set()).add(package)
        self.package_to_name.setdefault(package, name)
        self.packages.add(package)


def load_bundle_index(source: str) -> BundleIndex:
    index = BundleIndex()
    url = f"https://github.com/{source}/releases/latest/download/patches-list.json"
    try:
        data = fetch_json(url)
    except urllib.error.HTTPError as error:
        index.error = f"HTTP {error.code} from {url}"
        return index
    except Exception as error:  # noqa: BLE001 - best-effort fallback
        index.error = f"{type(error).__name__}: {error}"
        return index

    patches = data.get("patches", []) if isinstance(data, dict) else []
    for patch in patches:
        for package_info in patch.get("compatiblePackages") or []:
            if not isinstance(package_info, dict):
                continue
            index.add(package_info.get("name") or "", package_info.get("packageName") or "")

    if not index.packages:
        index.error = "patches-list.json contains no compatible packages"
    return index


@dataclass
class AppRecord:
    table: str
    file: str
    package: str | None
    source: str | None


def package_of(values: dict) -> str | None:
    for key in (
        "morphe-dlurl",
        "aptoide-dlurl",
        "apkeep-dlurl",
        "gplaydl-dlurl",
        "pkg-name",
    ):
        value = values.get(key)
        if isinstance(value, str) and PACKAGE_RE.fullmatch(value):
            return value
    return None


def table_values(table: Table, *, include_commented: bool = False) -> dict[str, str]:
    values: dict[str, str] = {}
    for key, item in table.items_by_key.items():
        if item.commented and not include_commented:
            continue
        raw = item.value.strip()
        if len(raw) >= 2 and raw[0] == '"' and raw[-1] == '"':
            raw = raw[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        values[key] = raw
    return values


def load_index() -> tuple[list[AppRecord], dict[str, list[AppRecord]]]:
    records: list[AppRecord] = []
    by_table: dict[str, list[AppRecord]] = {}
    for file in sorted(glob.glob("configs/*.toml")):
        text = Path(file).read_text(encoding="utf-8")
        tomllib.loads(text)  # fail early on invalid TOML
        _, tables = parse_document(text)
        for table in tables:
            active = table_values(table)
            # Commented package keys still identify the app; a maintainer may
            # have disabled that download source, not changed the app.
            everything = table_values(table, include_commented=True)
            values = {**everything, **active}
            record = AppRecord(
                table=table.name,
                file=file,
                package=package_of(values),
                source=values.get("patches-source") or values.get("patches-sources"),
            )
            records.append(record)
            by_table.setdefault(table.name, []).append(record)

    duplicates = {name: items for name, items in by_table.items() if len(items) > 1}
    if duplicates:
        details = "; ".join(
            f"{name} in {', '.join(item.file for item in items)}"
            for name, items in sorted(duplicates.items())
        )
        raise Failure(f"duplicate table names across configs: {details}")
    return records, by_table


def candidate_lines(name_to_packages: dict[str, set[str]], keys: list[str]) -> str:
    lines = []
    for key in keys:
        packages = sorted(name_to_packages[key])
        for package in packages:
            lines.append(f"  {key}  {package}")
    return "\n".join(lines)


class Resolver:
    def __init__(
        self,
        source: str,
        records: list[AppRecord],
        *,
        verbose: bool = False,
    ):
        self.source = source
        self.records = records
        self.verbose = verbose
        self.bundle = load_bundle_index(source)
        if verbose and self.bundle.error:
            warn(f"bundle index for {source}: {self.bundle.error}")

    def note(self, message: str) -> None:
        if self.verbose:
            print(f"resolver: {message}", file=sys.stderr)

    def from_bundle(self, query: str) -> Resolved | None:
        bundle = self.bundle
        if bundle.error or not bundle.packages:
            return None

        if PACKAGE_RE.fullmatch(query):
            name = bundle.package_to_name.get(query)
            if name:
                self.note(f"matched package {query} in {self.source}")
                return Resolved(query, name, None, "bundle package")
            return None

        normalized = normalize_name(query)
        packages = bundle.name_to_packages.get(normalized)
        if packages:
            self.note(f"exact name match for '{query}' in {self.source}")
            return self.single_choice(normalized, packages, "bundle")

        close = difflib.get_close_matches(
            normalized, list(bundle.name_to_packages), n=5, cutoff=0.85
        )
        close = [key for key in close if bundle.name_to_packages.get(key)]
        if len(close) > 1:
            raise Failure(
                f"'{query}' is ambiguous in {self.source}.\n"
                f"Candidates:\n{candidate_lines(bundle.name_to_packages, close)}\n"
                "Pass --package or a more specific app name.",
                EXIT_AMBIGUOUS,
            )
        if len(close) == 1:
            return self.single_choice(
                close[0], bundle.name_to_packages[close[0]], "bundle (close match)"
            )
        return None

    def single_choice(
        self, normalized: str, packages: set[str], origin: str
    ) -> Resolved:
        if len(packages) > 1:
            lines = "\n".join(f"  {package}" for package in sorted(packages))
            raise Failure(
                f"'{normalized}' matches more than one package in {self.source}:\n"
                f"{lines}\nPass --package to choose one.",
                EXIT_AMBIGUOUS,
            )
        package = next(iter(packages))
        name = self.bundle.package_to_name.get(package) if self.bundle else None
        return Resolved(package, name, None, origin)

    def from_configs(self, query: str) -> Resolved | None:
        same_source = [
            record
            for record in self.records
            if record.source == self.source and record.package
        ]
        by_name: dict[str, list[AppRecord]] = {}
        for record in same_source:
            by_name.setdefault(normalize_name(record.table), []).append(record)

        if PACKAGE_RE.fullmatch(query):
            for record in same_source:
                if record.package == query:
                    self.note(f"matched package {query} in {record.file}")
                    return Resolved(query, None, record.table, "existing config")

        normalized = normalize_name(query)
        matches = by_name.get(normalized)
        if matches:
            return self.single_record(normalized, matches, "existing config")

        close = difflib.get_close_matches(normalized, list(by_name), n=5, cutoff=0.85)
        close = [key for key in close if by_name.get(key)]
        if len(close) > 1:
            lines = "\n".join(
                f"  {record.table}  {record.package}"
                for key in close
                for record in by_name[key]
            )
            raise Failure(
                f"'{query}' is ambiguous in existing {self.source} configs.\n"
                f"Candidates:\n{lines}\nPass --package.",
                EXIT_AMBIGUOUS,
            )
        if len(close) == 1:
            return self.single_record(
                close[0], by_name[close[0]], "existing config (close match)"
            )
        return None

    def single_record(
        self, normalized: str, records: list[AppRecord], origin: str
    ) -> Resolved:
        packages = {record.package for record in records}
        if len(packages) > 1:
            lines = "\n".join(
                f"  {record.table}  {record.package}" for record in records
            )
            raise Failure(
                f"'{normalized}' matches more than one package:\n{lines}\n"
                "Pass --package to choose one.",
                EXIT_AMBIGUOUS,
            )
        record = records[0]
        return Resolved(record.package or "", None, record.table, origin)

    def from_archive(self, query: str) -> Resolved | None:
        try:
            data = fetch_json(ARCHIVE_URL)
        except Exception as error:  # noqa: BLE001 - best-effort fallback
            self.note(f"morphe archive: {type(error).__name__}: {error}")
            return None

        name_to_packages: dict[str, set[str]] = {}
        for app in data.get("apps", []) if isinstance(data, dict) else []:
            name = app.get("name") or ""
            package = app.get("packageName") or ""
            if name and package:
                name_to_packages.setdefault(normalize_name(name), set()).add(package)

        if PACKAGE_RE.fullmatch(query):
            for packages in name_to_packages.values():
                if query in packages:
                    self.note(f"matched package {query} in morphe archive")
                    return Resolved(query, None, None, "morphe archive")

        normalized = normalize_name(query)
        packages = name_to_packages.get(normalized)
        if packages:
            if len(packages) == 1:
                return Resolved(
                    next(iter(packages)), None, None, "morphe archive"
                )
            raise Failure(
                f"'{query}' matches more than one package in the morphe archive.\n"
                f"Pass --package.",
                EXIT_AMBIGUOUS,
            )

        close = difflib.get_close_matches(
            normalized, list(name_to_packages), n=5, cutoff=0.85
        )
        close = [key for key in close if name_to_packages.get(key)]
        if len(close) > 1:
            raise Failure(
                f"'{query}' is ambiguous in the morphe archive.\n"
                f"Candidates:\n{candidate_lines(name_to_packages, close)}\n"
                "Pass --package.",
                EXIT_AMBIGUOUS,
            )
        if len(close) == 1:
            packages = name_to_packages[close[0]]
            if len(packages) == 1:
                return Resolved(
                    next(iter(packages)), None, None, "morphe archive (close match)"
                )
        return None

    def resolve(self, query: str, explicit_package: str | None) -> Resolved:
        if explicit_package:
            name = None
            if not self.bundle.error and self.bundle.packages:
                name = self.bundle.package_to_name.get(explicit_package)
                if not name:
                    warn(
                        f"package {explicit_package} is not listed in "
                        f"{self.source} target packages; writing it anyway"
                    )
            self.note(f"using explicit package {explicit_package}")
            return Resolved(explicit_package, name, None, "explicit package")

        for resolver in (self.from_bundle, self.from_configs, self.from_archive):
            resolved = resolver(query)
            if resolved and resolved.package:
                return resolved

        raise Failure(
            f"could not resolve a package for '{query}' from {self.source}.\n"
            "Pass the Android package explicitly:\n"
            f"  ./add-app.sh \"{query}\" {self.source} com.example.app"
        )


@dataclass
class Target:
    table: str
    file: str
    existing: AppRecord | None


def choose_target(
    *,
    args: argparse.Namespace,
    source: str,
    package: str,
    resolved: Resolved,
    app_input: str,
    records: list[AppRecord],
    by_table: dict[str, list[AppRecord]],
    owner: str,
    repo: str,
) -> Target:
    if args.table:
        table = validate_table_name(args.table)
        existing = by_table.get(table)
        if existing:
            record = existing[0]
            same_app = record.package == package and record.source == source
            if not same_app and not args.force:
                raise Failure(
                    f"table [{table}] already exists in {record.file} for "
                    f"{record.package or 'unknown package'} / "
                    f"{record.source or 'unknown source'}; "
                    "choose another --table or pass --force"
                )
            return Target(table, record.file, record)
        return Target(table, args.config_file or f"configs/{owner}-{repo}.toml", None)

    if not args.force_new:
        pairs = [
            record
            for record in records
            if record.package == package and record.source == source
        ]
        if len(pairs) > 1:
            stable = [record for record in pairs if not record.table.endswith("-Dev")]
            if len(stable) == 1:
                pairs = stable
            else:
                raise Failure(
                    f"{package} / {source} already has several tables: "
                    + ", ".join(f"{record.table} ({record.file})" for record in pairs)
                    + "\nPass --table to choose one."
                )
        if pairs:
            record = pairs[0]
            return Target(record.table, record.file, record)

    display = resolved.table_hint or resolved.name
    if not display and PACKAGE_RE.fullmatch(app_input):
        display = app_input.rsplit(".", 1)[-1].replace("_", " ")
    base = validate_table_name(slugify(display or app_input))

    candidates = [base, f"{base}-{slugify(owner)}", f"{base}-{slugify(owner)}-{slugify(repo)}"]
    if args.force_new:
        candidates.extend(f"{base}-{slugify(owner)}-{index}" for index in range(2, 20))

    for candidate in candidates:
        existing = by_table.get(candidate)
        if not existing:
            return Target(
                candidate, args.config_file or f"configs/{owner}-{repo}.toml", None
            )
        record = existing[0]
        if record.package == package and record.source == source and not args.force_new:
            return Target(candidate, record.file, record)
        if args.force:
            return Target(candidate, record.file, record)

    raise Failure(
        f"could not find a free table name for '{base}' "
        f"(tried {', '.join(candidates)})"
    )


def file_defaults(
    target_file: str,
) -> tuple[str | None, str | None, list[str], list[Table], str]:
    path = Path(target_file)
    if not path.exists():
        return None, None, [], [], ""

    text = path.read_text(encoding="utf-8")
    header, tables = parse_document(text)
    source, cli = header_source_and_cli(header)

    brands = Counter(
        table.items_by_key["rv-brand"].value
        for table in tables
        if "rv-brand" in table.items_by_key and not table.items_by_key["rv-brand"].commented
    )
    clis = Counter(
        table.items_by_key["cli-source"].value
        for table in tables
        if "cli-source" in table.items_by_key and not table.items_by_key["cli-source"].commented
    )
    brand = brands.most_common(1)[0][0].strip('"') if brands else None
    cli_value = clis.most_common(1)[0][0].strip('"') if clis else None
    return brand, cli_value, header, tables, text


def build_output(
    *,
    status: str,
    changed: bool,
    table: Table,
    target_file: str,
    package: str,
    source: str,
    app_name: str,
    brand: str,
    cli: str,
    dry_run: bool,
) -> dict:
    return {
        "status": status,
        "changed": changed,
        "table": table.name,
        "config_file": target_file,
        "package": package,
        "patch_source": source,
        "app_name": app_name,
        "rv_brand": brand,
        "cli_source": cli,
        "dry_run": dry_run,
        "table_toml": "\n".join(render_table(table)),
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Add or update an app in configs/*.toml using the canonical style."
    )
    parser.add_argument("app_name", nargs="?", help="app name or package name")
    parser.add_argument("patch_source", nargs="?", help="patch source in owner/repo form")
    parser.add_argument("package_name", nargs="?", help="Android package (optional)")
    parser.add_argument("config_file", nargs="?", help="destination config file (optional)")
    parser.add_argument("--app", dest="app_flag", help="app name or package name")
    parser.add_argument("--source", dest="source_flag", help="patch source owner/repo")
    parser.add_argument("--package", dest="package_flag", help="Android package")
    parser.add_argument("--table", help="exact config table name")
    parser.add_argument("--brand", help="rv-brand value")
    parser.add_argument("--cli-source", help="cli-source value")
    parser.add_argument("--config-file", dest="config_file_flag", help="destination config file")
    parser.add_argument("--json", action="store_true", help="print one JSON object")
    parser.add_argument("--dry-run", action="store_true", help="do not write the config")
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite a conflicting table and uncomment managed keys",
    )
    parser.add_argument(
        "--force-new",
        action="store_true",
        help="create a new table even if the app/source pair already exists",
    )
    parser.add_argument("--verbose", action="store_true", help="show resolver details")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    app_input = (args.app_flag or args.app_name or "").strip()
    source_input = (args.source_flag or args.patch_source or "").strip()
    package_input = (args.package_flag or args.package_name or "").strip() or None
    config_input = (args.config_file_flag or args.config_file or "").strip() or None

    if not app_input:
        raise Failure("missing app name (pass it positionally or with --app)")
    if not source_input:
        raise Failure("missing patch source (pass it positionally or with --source)")

    app_input = validate_app_name(app_input)
    owner, repo = validate_source(source_input)
    source = f"{owner}/{repo}"
    explicit_package = validate_package(package_input) if package_input else None

    records, by_table = load_index()
    resolver = Resolver(source, records, verbose=args.verbose)
    resolved = resolver.resolve(app_input, explicit_package)
    package = resolved.package

    target = choose_target(
        args=args,
        source=source,
        package=package,
        resolved=resolved,
        app_input=app_input,
        records=records,
        by_table=by_table,
        owner=owner,
        repo=repo,
    )
    if config_input:
        if target.existing and Path(target.file) != Path(config_input):
            raise Failure(
                f"[{target.table}] already exists in {target.file}; "
                f"refusing to create a duplicate table in {config_input}"
            )
        target.file = config_input

    old_brand, old_cli, header, tables, old_text = file_defaults(target.file)

    existing = next((table for table in tables if table.name == target.table), None)
    existing_brand = None
    existing_cli = None
    if existing is not None:
        item = existing.items_by_key.get("rv-brand")
        if item is not None and not item.commented:
            existing_brand = item.value.strip('"')
        item = existing.items_by_key.get("cli-source")
        if item is not None and not item.commented:
            existing_cli = item.value.strip('"')

    brand = validate_brand(
        args.brand or existing_brand or old_brand or BRAND_ALIASES.get(source, owner)
    )
    cli = args.cli_source or existing_cli or old_cli or CLI_ALIASES.get(source, DEFAULT_CLI)
    cli_owner, cli_repo = validate_source(cli)
    cli = f"{cli_owner}/{cli_repo}"

    managed_plain = {
        "patches-source": source,
        "cli-source": cli,
        "rv-brand": brand,
        "morphe-dlurl": package,
        "aptoide-dlurl": package,
        "apkeep-dlurl": package,
    }
    managed = {key: quote(value) for key, value in managed_plain.items()}

    if existing is None:
        new_table = merge_table(Table(target.table), managed)
        tables.append(new_table)
        status = "added"
    else:
        new_table = merge_table(
            existing, managed, uncomment_managed=args.force, add_missing=False
        )
        tables[tables.index(existing)] = new_table
        status = "updated"

    old_source, old_cli_header = header_source_and_cli(header)
    header_lines = render_header(
        old_source or source,
        old_cli_header or cli,
        header_extras(header) if header else [],
    )
    new_text = render_document(header_lines, [sort_table(table) for table in tables])
    changed = new_text != old_text

    # Guard: the formatter may only touch the requested table.
    old_parsed = tomllib.loads(old_text) if old_text.strip() else {}
    new_parsed = tomllib.loads(new_text)
    old_tables = {key: value for key, value in old_parsed.items() if isinstance(value, dict)}
    new_tables = {key: value for key, value in new_parsed.items() if isinstance(value, dict)}
    if set(new_tables) != set(old_tables) | {target.table}:
        raise Failure(
            f"internal error: table set changed unexpectedly while writing {target.file}"
        )
    for name, values in old_tables.items():
        if name != target.table and new_tables[name] != values:
            raise Failure(
                f"internal error: [{name}] would change while writing {target.file}"
            )
    for key, value in managed_plain.items():
        if key in new_tables[target.table] and new_tables[target.table][key] != value:
            raise Failure(
                f"internal error: [{target.table}] {key} was not written correctly"
            )
    if target.table in old_tables:
        for key, value in old_tables[target.table].items():
            if key in managed_plain:
                continue
            if new_tables[target.table].get(key) != value:
                raise Failure(
                    f"internal error: [{target.table}] {key} was modified unexpectedly"
                )

    if changed and not args.dry_run:
        Path(target.file).parent.mkdir(parents=True, exist_ok=True)
        Path(target.file).write_text(new_text, encoding="utf-8")

    result = build_output(
        status=status,
        changed=changed,
        table=new_table,
        target_file=target.file,
        package=package,
        source=source,
        app_name=resolved.name or app_input,
        brand=brand,
        cli=cli,
        dry_run=args.dry_run,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if not changed:
            print(f"No change needed; [{target.table}] in {target.file} is already current.")
        elif args.dry_run:
            print(f"Would {status} table [{target.table}] in {target.file}:")
            print(result["table_toml"])
        else:
            print(f"[+] Successfully {status} table [{target.table}] to {target.file}")
        print(f"    Package: {package}")
        print(f"    Patch Source: {source}")
        print(f"    CLI Source: {cli}")
        print(f"    Brand: {brand}")
        if changed:
            print(f"    Resolution: {resolved.origin}")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(error.code)
