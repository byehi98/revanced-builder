#!/usr/bin/env python3
"""Canonical formatting for ``configs/*.toml``.

Every config file follows the same shape:

* a header naming the patches bundle and CLI,
* one blank line, then the ``DL_SRCS`` note copied from ``utils.sh``,
* one blank line before each table,
* keys ordered ``patches-source`` -> ``cli-source`` -> ``rv-brand`` ->
  ``patches-version`` -> ``version`` -> download sources in ``DL_SRCS`` order,
* ``=`` aligned at column 16, spaces only, a final newline and no trailing
  whitespace.

The helpers here are deliberately line based: comments belong to the key that
follows them, so they survive re-ordering and in-place updates.  Use
``normalise_document`` when writing generated config and ``merge_table`` when
updating an existing app without touching keys the script does not own.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

KEY_WIDTH = 16

TABLE_RE = re.compile(r"^\[([^\[\]]+)\]\s*$")
ASSIGN_RE = re.compile(r"^([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*$")
COMMENT_ASSIGN_RE = re.compile(r"^#\s*([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*$")

# Keep in sync with DL_SRCS in utils.sh.
DL_KEYS = [
    "morphe-dlurl",
    "aptoide-dlurl",
    "apkeep-dlurl",
    "apkcombo-dlurl",
    "apkmirror-dlurl",
    "apkpure-dlurl",
    "archive-dlurl",
    "direct-dlurl",
    "gplaydl-dlurl",
    "uptodown-dlurl",
]

META_KEYS = [
    "patches-source",
    "patches-sources",
    "cli-source",
    "cli-sources",
    "rv-brand",
    "patches-version",
    "app-name",
    "version",
    "enabled",
    "build-mode",
    "module-prop-name",
]

KEY_ORDER = {key: index for index, key in enumerate(META_KEYS)}
for _index, _key in enumerate(DL_KEYS):
    KEY_ORDER[_key] = len(META_KEYS) + _index

DL_COMMENT_LINES = [
    "# every <source>-dlurl below is tried in DL_SRCS order",
    "# (morphe, aptoide, apkeep, apkcombo, apkmirror, apkpure, archive, direct, gplaydl, uptodown) and the next one",
    "# is used when the current one cannot serve the required version.",
]

STD_HEADER_PATTERNS = (
    re.compile(r"^#\s+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\s*$"),
    re.compile(r"^#\s*$"),
    re.compile(r"^#\s*Patches bundle:\s*https://github\.com/\S+\s*$"),
    re.compile(r"^#\s*CLI:\s*https://github\.com/\S+\s*$"),
    re.compile(r"^#\s*every <source>-dlurl below is tried in DL_SRCS order\s*$"),
    re.compile(r"^#\s*\(morphe,.*\) and the next one\s*$"),
    re.compile(r"^#\s*is used when the current one cannot serve the required version\.\s*$"),
)


@dataclass
class Item:
    key: str
    value: str
    commented: bool = False
    comments: list[str] = field(default_factory=list)
    index: int = 0


@dataclass
class Table:
    name: str
    items: list[Item] = field(default_factory=list)
    trailing: list[str] = field(default_factory=list)

    @property
    def items_by_key(self) -> dict[str, Item]:
        """First item for each key, so callers can inspect a table quickly."""
        result: dict[str, Item] = {}
        for item in self.items:
            result.setdefault(item.key, item)
        return result


def quote(value: str) -> str:
    """Return ``value`` as a basic TOML string."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def table_sort_key(item: Item) -> tuple[int, int]:
    return (KEY_ORDER.get(item.key, 1000), item.index)


def parse_table(name: str, body: list[str]) -> Table:
    items: list[Item] = []
    trailing: list[str] = []
    pending: list[str] = []

    for raw in body:
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            continue

        match = ASSIGN_RE.match(line)
        if match:
            items.append(
                Item(match.group(1), match.group(2).strip(), False, pending, len(items))
            )
            pending = []
            continue

        match = COMMENT_ASSIGN_RE.match(stripped)
        if match:
            items.append(
                Item(match.group(1), match.group(2).strip(), True, pending, len(items))
            )
            pending = []
            continue

        pending.append(stripped)

    trailing.extend(pending)
    return Table(name, items, trailing)


def parse_document(text: str) -> tuple[list[str], list[Table]]:
    """Split a config into its header lines and tables."""
    lines = text.splitlines()
    header: list[str] = []
    index = 0
    while index < len(lines) and not TABLE_RE.match(lines[index]):
        header.append(lines[index])
        index += 1

    tables: list[Table] = []
    while index < len(lines):
        match = TABLE_RE.match(lines[index])
        if not match:
            index += 1
            continue
        name = match.group(1)
        index += 1
        body: list[str] = []
        while index < len(lines) and not TABLE_RE.match(lines[index]):
            body.append(lines[index])
            index += 1
        tables.append(parse_table(name, body))

    return header, tables


def header_source_and_cli(header: list[str]) -> tuple[str | None, str | None]:
    source: str | None = None
    cli: str | None = None
    for line in header:
        match = re.match(
            r"^#\s+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\s*$", line
        )
        if match and source is None:
            source = match.group(1)
            continue
        match = re.match(
            r"^#\s*Patches bundle:\s*https://github\.com/(\S+)\s*$", line
        )
        if match:
            source = match.group(1)
            continue
        match = re.match(r"^#\s*CLI:\s*https://github\.com/(\S+)\s*$", line)
        if match:
            cli = match.group(1)
    return source, cli


def header_extras(header: list[str]) -> list[str]:
    """Return file-specific notes, dropping the standard header lines."""
    extras = []
    for line in header:
        stripped = line.rstrip()
        if not stripped.strip():
            continue
        if any(pattern.match(stripped) for pattern in STD_HEADER_PATTERNS):
            continue
        extras.append(stripped)
    return extras


def render_header(source: str, cli: str, extras: list[str]) -> list[str]:
    lines = [
        f"# {source}",
        "#",
        f"# Patches bundle: https://github.com/{source}",
        f"# CLI:            https://github.com/{cli}",
        "",
        *DL_COMMENT_LINES,
    ]
    if extras:
        lines.extend(["", *extras])
    return lines


def render_assignment(key: str, value: str, commented: bool = False) -> str:
    prefix = "# " if commented else ""
    return f"{prefix}{key:<{KEY_WIDTH}}= {value}".rstrip()


def render_table(table: Table) -> list[str]:
    lines = [f"[{table.name}]"]
    for item in table.items:
        lines.extend(item.comments)
        lines.append(render_assignment(item.key, item.value, item.commented))
    lines.extend(table.trailing)
    return lines


def render_document(header: list[str], tables: list[Table]) -> str:
    parts = ["\n".join(header).rstrip("\n")]
    parts.extend("\n".join(render_table(table)) for table in tables)
    return "\n\n".join(parts).rstrip() + "\n"


def sort_table(table: Table) -> Table:
    table.items = sorted(table.items, key=table_sort_key)
    return table


def merge_table(
    table: Table,
    managed: dict[str, str],
    *,
    uncomment_managed: bool = False,
    add_missing: bool = True,
) -> Table:
    """Update only the keys in *managed*, preserving comments and other keys.

    Commented-out managed keys describe download sources that a maintainer
    deliberately disabled, so they stay commented unless *uncomment_managed*
    is set.  Existing tables keep their current key set unless *add_missing*
    is set; new tables are created with every managed key.
    """
    items = list(table.items)
    for key, value in managed.items():
        existing = next((item for item in items if item.key == key), None)
        if existing is None:
            if add_missing:
                items.append(Item(key, value, False, [], len(items)))
            continue
        if existing.commented and not uncomment_managed:
            continue
        existing.value = value
        existing.commented = False

    return sort_table(Table(table.name, items, list(table.trailing)))


def normalise_document(
    text: str,
    *,
    source: str,
    cli: str,
    extras: list[str] | None = None,
) -> str:
    """Rewrite *text* in the canonical layout.

    The existing header is kept when it already names a bundle, so a file is
    never silently re-labelled just because it was normalised.
    """
    header, tables = parse_document(text)
    old_source, old_cli = header_source_and_cli(header)
    notes = header_extras(header) if extras is None else list(extras)
    header_lines = render_header(old_source or source, old_cli or cli, notes)
    return render_document(header_lines, [sort_table(table) for table in tables])


def is_valid_table_name(name: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name))
