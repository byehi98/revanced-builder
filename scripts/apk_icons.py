#!/usr/bin/env python3
"""Read APK launcher icons using HTTP range requests.

This module intentionally has no third-party dependencies.  It parses the
binary AndroidManifest.xml and resources.arsc formats directly and renders the
small subset of drawable XML that launcher icons use.  ImageMagick is only
required when an icon has to be rasterised (``render_to_png``); callers that
serve committed PNGs never need it.
"""
from __future__ import annotations

import shutil
import struct
import subprocess
import tempfile
import urllib.request
import zlib
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------- #
# remote zip
# --------------------------------------------------------------------------- #


class RemoteZip:
    def __init__(self, url: str, size: int, timeout: int = 90):
        self.url = url
        self.size = size
        self.timeout = timeout
        self._entries: dict[str, tuple[int, int, int, int, int]] | None = None
        self._cache: dict[str, bytes] = {}

    def _fetch(self, start: int, end: int) -> bytes:
        if start < 0 or end >= self.size or start > end:
            raise ValueError(f"bad range {start}-{end} for size {self.size}")
        req = urllib.request.Request(
            self.url,
            headers={
                "Range": f"bytes={start}-{end}",
                "User-Agent": "rvb-icon-fetcher/1.0",
            },
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            if resp.status != 206:
                raise RuntimeError(f"range request returned HTTP {resp.status}")
            data = resp.read()
        if len(data) != end - start + 1:
            raise RuntimeError(f"short range response: {len(data)} != {end - start + 1}")
        return data

    def entries(self) -> dict[str, tuple[int, int, int, int, int]]:
        if self._entries is not None:
            return self._entries
        tail = self._fetch(max(0, self.size - 65557), self.size - 1)
        pos = tail.rfind(b"PK\x05\x06")
        if pos < 0:
            raise ValueError("end of central directory not found")
        (disk, cd_disk, disk_entries, total_entries, cd_size, cd_offset, comment_len) = struct.unpack_from(
            "<HHHHIIH", tail, pos + 4
        )
        if total_entries == 0xFFFF or cd_size == 0xFFFFFFFF or cd_offset == 0xFFFFFFFF:
            raise ValueError("ZIP64 APK is not supported")
        cd = self._fetch(cd_offset, cd_offset + cd_size - 1)
        entries: dict[str, tuple[int, int, int, int, int]] = {}
        p = 0
        while p + 46 <= len(cd) and cd[p : p + 4] == b"PK\x01\x02":
            flags, method = struct.unpack_from("<HH", cd, p + 8)
            crc, csize, usize = struct.unpack_from("<III", cd, p + 16)
            fnlen, extralen, comlen = struct.unpack_from("<HHH", cd, p + 28)
            local_offset = struct.unpack_from("<I", cd, p + 42)[0]
            name = cd[p + 46 : p + 46 + fnlen].decode("utf-8", "replace")
            entries[name] = (method, csize, usize, local_offset, flags)
            p += 46 + fnlen + extralen + comlen
        self._entries = entries
        return entries

    def read(self, name: str) -> bytes:
        if name in self._cache:
            return self._cache[name]
        entries = self.entries()
        if name not in entries:
            raise KeyError(name)
        method, csize, usize, local_offset, flags = entries[name]
        header = self._fetch(local_offset, local_offset + 29)
        if header[:4] != b"PK\x03\x04":
            raise ValueError(f"bad local header for {name}")
        fnlen, extralen = struct.unpack_from("<HH", header, 26)
        data_start = local_offset + 30 + fnlen + extralen
        compressed = self._fetch(data_start, data_start + csize - 1)
        if method == 0:
            data = compressed
        elif method == 8:
            data = zlib.decompress(compressed, -15)
        else:
            raise ValueError(f"unsupported compression method {method} for {name}")
        if len(data) != usize:
            raise ValueError(f"size mismatch for {name}: {len(data)} != {usize}")
        self._cache[name] = data
        return data


# --------------------------------------------------------------------------- #
# binary XML
# --------------------------------------------------------------------------- #

RES_STRING_POOL_TYPE = 0x0001
RES_XML_TYPE = 0x0003
RES_XML_START_ELEMENT_TYPE = 0x0102
RES_XML_END_ELEMENT_TYPE = 0x0103
RES_XML_RESOURCE_MAP_TYPE = 0x0180
RES_TABLE_TYPE = 0x0002
RES_TABLE_PACKAGE_TYPE = 0x0200
RES_TABLE_TYPE_TYPE = 0x0201
RES_TABLE_TYPE_SPEC_TYPE = 0x0202

TYPE_REFERENCE = 0x01
TYPE_STRING = 0x03
TYPE_FLOAT = 0x04
TYPE_DIMENSION = 0x05
TYPE_INT_DEC = 0x10
TYPE_INT_HEX = 0x11
TYPE_INT_BOOLEAN = 0x12
TYPE_FIRST_COLOR_INT = 0x1C
TYPE_LAST_COLOR_INT = 0x1F


def color_tuple(data_type: int, data: int) -> tuple[int, int, int, int] | None:
    """Decode the four Android Res_value color encodings to ARGB."""

    if data_type == 0x1C:  # ARGB8 (stored as 0xAARRGGBB)
        return ((data >> 16) & 0xFF, (data >> 8) & 0xFF, data & 0xFF, (data >> 24) & 0xFF)
    if data_type == 0x1D:  # RGB8 (stored as 0xAARRGGBB with opaque alpha)
        return ((data >> 16) & 0xFF, (data >> 8) & 0xFF, data & 0xFF, 255)
    if data_type == 0x1E:  # ARGB4
        return (
            ((data >> 8) & 0xF) * 17,
            ((data >> 4) & 0xF) * 17,
            (data & 0xF) * 17,
            ((data >> 12) & 0xF) * 17,
        )
    if data_type == 0x1F:  # RGB4
        return (((data >> 8) & 0xF) * 17, ((data >> 4) & 0xF) * 17, (data & 0xF) * 17, 255)
    return None


def _decode_len8(data: bytes, p: int) -> tuple[int, int]:
    n = data[p]
    if n & 0x80:
        n = ((n & 0x7F) << 8) | data[p + 1]
        return n, p + 2
    return n, p + 1


def _decode_len16(data: bytes, p: int) -> tuple[int, int]:
    n = struct.unpack_from("<H", data, p)[0]
    if n & 0x8000:
        n2 = struct.unpack_from("<H", data, p + 2)[0]
        n = ((n & 0x7FFF) << 16) | n2
        return n, p + 4
    return n, p + 2


class StringPool:
    def __init__(self, data: bytes, offset: int = 0):
        self.data = data
        self.offset = offset
        chunk_type, header_size, size = struct.unpack_from("<HHI", data, offset)
        if chunk_type != RES_STRING_POOL_TYPE:
            raise ValueError(f"not a string pool: {chunk_type:#x}")
        self.count, self.style_count, self.flags, strings_start, styles_start = struct.unpack_from(
            "<IIIII", data, offset + 8
        )
        self.utf8 = bool(self.flags & 0x100)
        self.strings_start = offset + strings_start
        self.offsets = [struct.unpack_from("<I", data, offset + header_size + i * 4)[0] for i in range(self.count)]
        self._cache: dict[int, str] = {}

    def get(self, index: int) -> str:
        if index in self._cache:
            return self._cache[index]
        if index < 0 or index >= self.count:
            return ""
        p = self.strings_start + self.offsets[index]
        if self.utf8:
            # utf-16 length then utf-8 byte length
            _, p = _decode_len8(self.data, p)
            n, p = _decode_len8(self.data, p)
            value = self.data[p : p + n].decode("utf-8", "replace")
        else:
            n, p = _decode_len16(self.data, p)
            value = self.data[p : p + n * 2].decode("utf-16-le", "replace")
        self._cache[index] = value
        return value


@dataclass
class Attr:
    name: str
    resource_id: int
    raw: str | None
    data_type: int
    data: int


@dataclass
class Element:
    tag: str
    attrs: list[Attr]
    children: list["Element"] = field(default_factory=list)
    parent: "Element | None" = None

    def attr(self, name: str, resource_id: int | None = None) -> Attr | None:
        for a in self.attrs:
            if a.name == name or (resource_id is not None and a.resource_id == resource_id):
                return a
        return None

    def find_all(self, tag: str) -> list["Element"]:
        out: list[Element] = []
        for child in self.children:
            if child.tag == tag:
                out.append(child)
            out.extend(child.find_all(tag))
        return out


def parse_axml(data: bytes) -> Element:
    chunk_type, header_size, size = struct.unpack_from("<HHI", data, 0)
    if chunk_type != RES_XML_TYPE:
        raise ValueError("not an AXML document")
    pool: StringPool | None = None
    resmap: list[int] = []
    root: Element | None = None
    stack: list[Element] = []
    p = header_size
    while p + 8 <= len(data):
        ctype, cheader, csize = struct.unpack_from("<HHI", data, p)
        if csize < 8:
            break
        if ctype == RES_STRING_POOL_TYPE:
            pool = StringPool(data, p)
        elif ctype == RES_XML_RESOURCE_MAP_TYPE:
            n = (csize - cheader) // 4
            resmap = list(struct.unpack_from(f"<{n}I", data, p + cheader))
        elif ctype == RES_XML_START_ELEMENT_TYPE:
            if pool is None:
                raise ValueError("start element before string pool")
            node_off = p + cheader
            ns, name_idx, attr_start, attr_size, attr_count, id_idx, class_idx, style_idx = struct.unpack_from(
                "<IIHHHHHH", data, node_off
            )
            name = pool.get(name_idx)
            attrs: list[Attr] = []
            attr_off = node_off + attr_start
            for i in range(attr_count):
                a_ns, a_name, raw, v_size, v_res0, v_type, v_data = struct.unpack_from(
                    "<IIIHBBI", data, attr_off + i * attr_size
                )
                res_id = resmap[a_name] if a_name < len(resmap) else 0
                attrs.append(
                    Attr(
                        name=pool.get(a_name),
                        resource_id=res_id,
                        raw=pool.get(raw) if raw != 0xFFFFFFFF else None,
                        data_type=v_type,
                        data=v_data,
                    )
                )
            el = Element(name, attrs)
            if stack:
                el.parent = stack[-1]
                stack[-1].children.append(el)
            else:
                root = el
            stack.append(el)
        elif ctype == RES_XML_END_ELEMENT_TYPE:
            if stack:
                stack.pop()
        p += csize
    if root is None:
        raise ValueError("empty AXML document")
    return root


# --------------------------------------------------------------------------- #
# resources.arsc
# --------------------------------------------------------------------------- #


@dataclass
class ResValue:
    data_type: int
    data: int
    config: dict[str, int]
    key: str = ""
    type_name: str = ""


@dataclass
class Package:
    pkg_id: int
    name: str
    type_names: list[str]
    key_names: list[str]
    entries: dict[tuple[int, int], list[ResValue]] = field(default_factory=dict)


class ResourceTable:
    def __init__(self, data: bytes):
        self.data = data
        chunk_type, header_size, size = struct.unpack_from("<HHI", data, 0)
        if chunk_type != RES_TABLE_TYPE:
            raise ValueError("not a resources.arsc table")
        self.global_pool = StringPool(data, header_size)
        self.packages: dict[int, Package] = {}
        p = header_size
        while p + 8 <= len(data):
            ctype, cheader, csize = struct.unpack_from("<HHI", data, p)
            if csize < 8:
                break
            if ctype == RES_TABLE_PACKAGE_TYPE:
                self._read_package(p, cheader, csize)
            p += csize

    def _read_package(self, off: int, header_size: int, size: int) -> None:
        data = self.data
        pkg_id = struct.unpack_from("<I", data, off + 8)[0]
        name = data[off + 12 : off + 12 + 256].decode("utf-16-le", "replace").split("\x00", 1)[0]
        type_strings, last_type, key_strings, last_key = struct.unpack_from("<IIII", data, off + 268)
        type_id_offset = struct.unpack_from("<I", data, off + 284)[0] if header_size >= 288 else 0
        type_pool = StringPool(data, off + type_strings)
        key_pool = StringPool(data, off + key_strings)
        package = Package(
            pkg_id=pkg_id,
            name=name,
            type_names=[type_pool.get(i) for i in range(type_pool.count)],
            key_names=[key_pool.get(i) for i in range(key_pool.count)],
        )
        self.packages[pkg_id] = package

        p = off + header_size
        while p + 8 <= off + size:
            ctype, cheader, csize = struct.unpack_from("<HHI", data, p)
            if csize < 8:
                break
            if ctype == RES_TABLE_TYPE_TYPE:
                self._read_type(p, cheader, package, type_id_offset)
            p += csize

    def _read_type(self, off: int, header_size: int, package: Package, type_id_offset: int) -> None:
        data = self.data
        type_id = data[off + 8]
        flags = data[off + 9]
        entry_count, entries_start = struct.unpack_from("<II", data, off + 12)
        config_off = off + 20
        config_size = struct.unpack_from("<I", data, config_off)[0] if config_off + 4 <= len(data) else 0
        config = {
            "size": config_size,
            "density": struct.unpack_from("<H", data, config_off + 14)[0] if config_size >= 16 else 0,
            "sdk": struct.unpack_from("<H", data, config_off + 26)[0] if config_size >= 28 else 0,
        }
        actual_type = type_id + type_id_offset
        type_name = (
            package.type_names[type_id - 1]
            if 0 <= type_id - 1 < len(package.type_names)
            else str(type_id)
        )
        entries_base = off + entries_start

        def add_entry(index: int, entry_off: int) -> None:
            if entry_off < 0 or entries_base + entry_off + 8 > off + struct.unpack_from("<I", data, off + 4)[0]:
                return
            size16, flags16, key_idx = struct.unpack_from("<HHI", data, entries_base + entry_off)
            if flags16 & 0x0001:  # complex entry
                return
            if entries_base + entry_off + 16 > len(data):
                return
            v_size, v_res0, v_type, v_data = struct.unpack_from("<HBBI", data, entries_base + entry_off + 8)
            key = package.key_names[key_idx] if 0 <= key_idx < len(package.key_names) else ""
            package.entries.setdefault((actual_type, index), []).append(
                ResValue(v_type, v_data, config, key, type_name)
            )

        if flags & 0x01:  # sparse
            for i in range(entry_count):
                idx, value = struct.unpack_from("<HH", data, off + header_size + i * 4)
                add_entry(idx, value * 4)
        elif flags & 0x02:  # offset16
            for i in range(entry_count):
                value = struct.unpack_from("<H", data, off + header_size + i * 2)[0]
                if value != 0xFFFF:
                    add_entry(i, value * 4)
        else:
            for i in range(entry_count):
                value = struct.unpack_from("<I", data, off + header_size + i * 4)[0]
                if value != 0xFFFFFFFF:
                    add_entry(i, value)

    def values(self, res_id: int) -> list[ResValue]:
        pkg_id = (res_id >> 24) & 0xFF
        type_id = (res_id >> 16) & 0xFF
        entry = res_id & 0xFFFF
        package = self.packages.get(pkg_id)
        if not package:
            return []
        return package.entries.get((type_id, entry), [])

    def string(self, index: int) -> str:
        return self.global_pool.get(index)

    def resolve(self, res_id: int, depth: int = 0) -> list[ResValue]:
        """Follow references and return leaf values (paths, colors, ints)."""
        if depth > 12:
            return []
        out: list[ResValue] = []
        for value in self.values(res_id):
            if value.data_type == TYPE_REFERENCE:
                out.extend(self.resolve(value.data, depth + 1))
            else:
                out.append(value)
        return out

    def best_color(self, res_id: int) -> tuple[int, int, int, int] | None:
        colors = [
            v
            for v in self.resolve(res_id)
            if TYPE_FIRST_COLOR_INT <= v.data_type <= TYPE_LAST_COLOR_INT
        ]
        if not colors:
            return None
        value = colors[0]
        return color_tuple(value.data_type, value.data)


# --------------------------------------------------------------------------- #
# icon resolution
# --------------------------------------------------------------------------- #

IMAGE_EXTS = (".png", ".webp", ".jpg", ".jpeg")
ANDROID_ICON_ATTR = 0x0101020C
ANDROID_ROUND_ICON_ATTR = 0x0101052C
ANDROID_DRAWABLE_ATTR = 0x01010199
ANDROID_SRC_ATTR = 0x01010119

ICON_NAME_RE = __import__("re").compile(
    r"^(ic_launcher|ic-launcher|app_icon|appicon|icon|launcher|logo)(_[a-z0-9]+)?$", __import__("re").I
)


@dataclass
class Raster:
    name: str
    data: bytes
    width: int = 0
    height: int = 0


@dataclass
class Vector:
    name: str
    xml: Element
    table: ResourceTable


@dataclass
class Color:
    rgba: tuple[int, int, int, int]


@dataclass
class Composite:
    name: str
    foreground: "Raster | Vector"
    background: "Raster | Vector | Color | None"


Renderable = Raster | Vector | Composite


def _float(value: int) -> float:
    return struct.unpack("<f", struct.pack("<I", value))[0]


def _svg_color(rgba: tuple[int, int, int, int]) -> tuple[str, float]:
    r, g, b, a = rgba
    return f"#{r:02x}{g:02x}{b:02x}", a / 255.0


def vector_to_svg(vector: "Vector", size: int = 512, xml_loader=None) -> str:
    """Convert the common subset of Android VectorDrawable XML to SVG."""

    import html as _html
    import re as _re

    table = vector.table
    counter = [0]
    defs: list[str] = []

    def fattr(el: Element, name: str, default: float = 0.0) -> float:
        a = el.attr(name)
        if not a:
            return default
        if a.data_type == TYPE_FLOAT:
            return _float(a.data)
        if a.data_type in (TYPE_INT_DEC, TYPE_INT_HEX):
            return float(a.data)
        return default

    def iattr(el: Element, name: str, default: int = 0) -> int:
        a = el.attr(name)
        if not a:
            return default
        if a.data_type in (TYPE_INT_DEC, TYPE_INT_HEX, TYPE_FLOAT):
            return int(a.data)
        return default

    def sattr(el: Element, name: str, default: str = "") -> str:
        a = el.attr(name)
        if not a:
            return default
        if a.raw is not None:
            return a.raw
        if a.data_type == TYPE_STRING:
            return table.string(a.data)
        return default

    def color(el: Element, name: str) -> tuple[int, int, int, int] | None:
        a = el.attr(name)
        if not a:
            return None
        if a.data_type == TYPE_REFERENCE:
            return table.best_color(a.data)
        if TYPE_FIRST_COLOR_INT <= a.data_type <= TYPE_LAST_COLOR_INT:
            return color_tuple(a.data_type, a.data)
        if a.data_type in (TYPE_INT_DEC, TYPE_INT_HEX) and 0 <= a.data <= 0xFFFFFFFF:
            return color_tuple(0x1D if a.data <= 0xFFFFFF else 0x1C, a.data)
        return None

    def gradient_def(el: Element) -> str | None:
        kind = iattr(el, "type", 0)
        stops: list[tuple[float, tuple[int, int, int, int]]] = []
        for item in el.children:
            if item.tag != "item":
                continue
            c = color(item, "color")
            if c is None:
                continue
            stops.append((fattr(item, "offset", 0.0), c))
        if not stops:
            return None
        stops.sort(key=lambda item: item[0])
        gid = f"grad{counter[0]}"
        counter[0] += 1
        stop_markup = "".join(
            f'<stop offset="{offset:.4f}" stop-color="{_svg_color(c)[0]}" stop-opacity="{_svg_color(c)[1]:.4f}"/>'
            for offset, c in stops
        )
        if kind == 1:
            cx = fattr(el, "centerX", 0.0)
            cy = fattr(el, "centerY", 0.0)
            radius = fattr(el, "gradientRadius", 0.0)
            defs.append(
                f'<radialGradient id="{gid}" cx="{cx}" cy="{cy}" r="{max(radius, 0.0001)}" gradientUnits="userSpaceOnUse">{stop_markup}</radialGradient>'
            )
        elif kind == 2:
            # SVG has no sweep gradient; use the first stop as a solid fallback.
            r, g, b, a = stops[0][1]
            defs.append(f'<linearGradient id="{gid}"><stop offset="0" stop-color="#{r:02x}{g:02x}{b:02x}" stop-opacity="{a/255:.4f}"/></linearGradient>')
        else:
            x1, y1 = fattr(el, "startX", 0.0), fattr(el, "startY", 0.0)
            x2, y2 = fattr(el, "endX", 0.0), fattr(el, "endY", 0.0)
            defs.append(
                f'<linearGradient id="{gid}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" gradientUnits="userSpaceOnUse">{stop_markup}</linearGradient>'
            )
        return f"url(#{gid})"

    def gradient_from_ref(attr: Attr) -> str | None:
        if xml_loader is None:
            return None
        for value in table.resolve(attr.data):
            if value.data_type != TYPE_STRING:
                continue
            path = table.string(value.data)
            if not path or not path.lower().endswith(".xml"):
                continue
            doc = xml_loader(path)
            if doc is not None and doc.tag == "gradient":
                return gradient_def(doc)
        return None

    def render_node(el: Element) -> str:
        if el.tag == "path":
            d = sattr(el, "pathData")
            if not d:
                return ""
            attrs = [f'd="{_html.escape(d, quote=True)}"']
            fill = color(el, "fillColor")
            gradient = None
            fill_attr = el.attr("fillColor")
            if fill_attr is not None and fill_attr.data_type == TYPE_REFERENCE:
                gradient = gradient_from_ref(fill_attr)
            if not gradient:
                for child in el.children:
                    for grad in child.find_all("gradient"):
                        gradient = gradient_def(grad)
                        break
                    if gradient:
                        break
            if gradient:
                attrs.append(f'fill="{gradient}"')
                attrs.append(f'fill-opacity="{fattr(el, "fillAlpha", 1.0):.4f}"')
            elif fill is not None:
                fill_hex, fill_alpha = _svg_color(fill)
                attrs.append(f'fill="{fill_hex}"')
                attrs.append(f'fill-opacity="{fill_alpha * fattr(el, "fillAlpha", 1.0):.4f}"')
            else:
                attrs.append('fill="none"')

            stroke = color(el, "strokeColor")
            if stroke is not None:
                stroke_hex, stroke_alpha = _svg_color(stroke)
                attrs.append(f'stroke="{stroke_hex}"')
                attrs.append(f'stroke-opacity="{stroke_alpha * fattr(el, "strokeAlpha", 1.0):.4f}"')
                attrs.append(f'stroke-width="{fattr(el, "strokeWidth", 0.0)}"')
                linecap = iattr(el, "strokeLineCap", 0)
                attrs.append(f'stroke-linecap="{["butt", "round", "square"][linecap] if 0 <= linecap <= 2 else "butt"}"')
                linejoin = iattr(el, "strokeLineJoin", 0)
                attrs.append(f'stroke-linejoin="{["miter", "round", "bevel"][linejoin] if 0 <= linejoin <= 2 else "miter"}"')
            if iattr(el, "fillType", 0) == 1 or sattr(el, "fillType") == "evenOdd":
                attrs.append('fill-rule="evenodd"')
            return f'<path {" ".join(attrs)}/>'

        if el.tag == "group":
            tx, ty = fattr(el, "translateX", 0.0), fattr(el, "translateY", 0.0)
            sx, sy = fattr(el, "scaleX", 1.0), fattr(el, "scaleY", 1.0)
            rot = fattr(el, "rotation", 0.0)
            px, py = fattr(el, "pivotX", 0.0), fattr(el, "pivotY", 0.0)
            parts: list[str] = []
            if tx or ty or px or py:
                parts.append(f"translate({tx + px} {ty + py})")
            if rot:
                parts.append(f"rotate({rot})")
            if sx != 1.0 or sy != 1.0:
                parts.append(f"scale({sx} {sy})")
            if px or py:
                parts.append(f"translate({-px} {-py})")
            attrs = []
            if parts:
                attrs.append(f'transform="{" ".join(parts)}"')
            alpha = fattr(el, "alpha", 1.0)
            if alpha != 1.0:
                attrs.append(f'opacity="{alpha:.4f}"')
            inner = render_children(el.children)
            extra = f' {" ".join(attrs)}' if attrs else ""
            return f"<g{extra}>{inner}</g>"

        if el.tag == "clip-path":
            d = sattr(el, "pathData")
            if not d:
                return ""
            cid = f"clip{counter[0]}"
            counter[0] += 1
            defs.append(f'<clipPath id="{cid}"><path d="{_html.escape(d, quote=True)}"/></clipPath>')
            return f'<g clip-path="url(#{cid})">'

        return ""

    def render_children(children: list[Element]) -> str:
        out: list[str] = []
        clip_open = False
        for child in children:
            if child.tag == "clip-path":
                markup = render_node(child)
                if markup:
                    out.append(markup)
                    clip_open = True
                continue
            if child.tag in ("path", "group"):
                out.append(render_node(child))
        if clip_open:
            out.append("</g>")
        return "".join(out)

    vw = fattr(vector.xml, "viewportWidth", 24.0) or 24.0
    vh = fattr(vector.xml, "viewportHeight", 24.0) or 24.0
    root_alpha = fattr(vector.xml, "alpha", 1.0)
    body = render_children(vector.xml.children)
    opacity = f' opacity="{root_alpha:.4f}"' if root_alpha != 1.0 else ""
    defs_markup = f"<defs>{''.join(defs)}</defs>" if defs else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
        f'viewBox="0 0 {vw} {vh}"{opacity}>{defs_markup}{body}</svg>'
    )


class IconResolver:
    def __init__(self, apk: RemoteZip):
        self.apk = apk
        self.manifest = parse_axml(apk.read("AndroidManifest.xml"))
        self.table = ResourceTable(apk.read("resources.arsc"))
        self._raster_cache: dict[str, bytes] = {}

    # -- manifest ----------------------------------------------------------
    def manifest_icon_ids(self) -> list[int]:
        ids: list[int] = []
        apps = self.manifest.find_all("application")
        for app in apps:
            for attr_id in (ANDROID_ICON_ATTR, ANDROID_ROUND_ICON_ATTR):
                attr = app.attr("icon", attr_id) if attr_id == ANDROID_ICON_ATTR else app.attr("roundIcon", attr_id)
                if attr and attr.data_type == TYPE_REFERENCE:
                    if attr.data not in ids:
                        ids.append(attr.data)
        return ids

    def named_icon_ids(self) -> list[int]:
        found: list[tuple[int, int, int]] = []
        for package in self.table.packages.values():
            for (type_id, entry), values in package.entries.items():
                key = values[0].key if values else ""
                if ICON_NAME_RE.match(key):
                    res_id = (package.pkg_id << 24) | (type_id << 16) | entry
                    score = 0
                    if key in ("ic_launcher", "app_icon", "icon"):
                        score = 2
                    elif key.startswith("ic_launcher"):
                        score = 1
                    found.append((score, -entry, res_id))
        found.sort(reverse=True)
        return [res_id for _, _, res_id in found]

    # -- resources --------------------------------------------------------
    @staticmethod
    def _path_score(path: str) -> int:
        low = path.lower()
        score = 0
        if "night" in low:
            score -= 1000
        if "dark" in low:
            score -= 500
        if "round" in low:
            score += 30
        import re as _re

        match = _re.search(r"(?:^|[-/])(ldpi|mdpi|hdpi|xhdpi|xxhdpi|xxxhdpi)(?:[-/]|$)", low)
        if match:
            score += ["ldpi", "mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"].index(match.group(1)) + 1
        return score

    def _raster(self, path: str) -> Raster | None:
        if path in self._raster_cache:
            return Raster(path, self._raster_cache[path])
        try:
            data = self.apk.read(path)
        except (KeyError, ValueError):
            return None
        self._raster_cache[path] = data
        return Raster(path, data)

    def _xml(self, path: str) -> Element | None:
        try:
            return parse_axml(self.apk.read(path))
        except (KeyError, ValueError):
            return None

    @staticmethod
    def _str_attr(attr: Attr) -> str:
        if attr.raw is not None:
            return attr.raw
        return ""

    def _renderable_from_value(self, value: ResValue) -> Renderable | None:
        if value.data_type == TYPE_STRING:
            path = self.table.string(value.data)
            if not path:
                return None
            if path.lower().endswith(IMAGE_EXTS):
                return self._raster(path)
            if path.lower().endswith(".xml"):
                return self._from_xml(path)
            return None
        if TYPE_FIRST_COLOR_INT <= value.data_type <= TYPE_LAST_COLOR_INT:
            argb = color_tuple(value.data_type, value.data)
            return Color(argb) if argb else None
        return None

    def _from_xml(self, path: str) -> Renderable | None:
        root = self._xml(path)
        if root is None:
            return None
        tag = root.tag
        if tag == "vector":
            return Vector(path, root, self.table)
        if tag == "color":
            attr = root.attr("color")
            if attr:
                if attr.data_type == TYPE_REFERENCE:
                    color = self.table.best_color(attr.data)
                elif TYPE_FIRST_COLOR_INT <= attr.data_type <= TYPE_LAST_COLOR_INT:
                    color = color_tuple(attr.data_type, attr.data)
                else:
                    color = None
                if color:
                    return Color(color)
            return None
        if tag == "shape":
            for child in root.children:
                if child.tag == "solid":
                    attr = child.attr("color")
                    if attr:
                        color = (
                            self.table.best_color(attr.data)
                            if attr.data_type == TYPE_REFERENCE
                            else color_tuple(attr.data_type, attr.data)
                        )
                        if color:
                            return Color(color)
            return None
        if tag == "adaptive-icon":
            fg = bg = None
            for child in root.children:
                if child.tag == "foreground":
                    fg = self._drawable_attr(child)
                elif child.tag == "background":
                    bg = self._drawable_attr(child)
            if fg is not None:
                return Composite(path, fg, bg)
            return None
        if tag == "bitmap":
            src = self._drawable_attr(root, ANDROID_SRC_ATTR, "src")
            if isinstance(src, Raster):
                return src
            return None
        if tag in ("inset", "clip", "ripple"):
            drawable = root.attr("drawable", ANDROID_DRAWABLE_ATTR)
            if drawable:
                result = self._drawable_attr(root)
                if result:
                    return result
        if tag in ("layer-list", "selector", "inset", "clip", "ripple", "animated-selector", "transition"):
            for child in root.children:
                drawable = child.attr("drawable", ANDROID_DRAWABLE_ATTR)
                if drawable and drawable.data_type == TYPE_REFERENCE:
                    result = self._best_from_res_id(drawable.data)
                    if result:
                        return result
                nested = self._from_xml_element(child)
                if nested:
                    return nested
            return None
        return self._from_xml_element(root)

    def _from_xml_element(self, el: Element) -> Renderable | None:
        for child in el.children:
            if child.tag == "vector":
                return Vector("vector", child, self.table)
            drawable = child.attr("drawable", ANDROID_DRAWABLE_ATTR)
            if drawable and drawable.data_type == TYPE_REFERENCE:
                result = self._best_from_res_id(drawable.data)
                if result:
                    return result
            if child.tag in ("vector", "bitmap", "layer-list", "selector", "adaptive-icon", "inset", "clip", "ripple", "shape", "color"):
                nested = self._from_xml_element(child)
                if nested:
                    return nested
        return None

    def _drawable_attr(
        self, el: Element, resource_id: int = ANDROID_DRAWABLE_ATTR, name: str = "drawable"
    ) -> Renderable | None:
        attr = el.attr(name, resource_id)
        if not attr:
            return None
        if attr.data_type == TYPE_REFERENCE:
            result = self._best_from_res_id(attr.data)
            if result is not None:
                return result
            # <background android:drawable="@color/..."/> resolves to a Color,
            # which is deliberately excluded from icon candidates.
            for value in self.table.resolve(attr.data):
                renderable = self._renderable_from_value(value)
                if isinstance(renderable, Color):
                    return renderable
            return None
        if attr.data_type == TYPE_STRING:
            path = self._str_attr(attr) or self.table.string(attr.data)
            if path.lower().endswith(IMAGE_EXTS):
                return self._raster(path)
            if path.lower().endswith(".xml"):
                return self._from_xml(path)
        if TYPE_FIRST_COLOR_INT <= attr.data_type <= TYPE_LAST_COLOR_INT:
            argb = color_tuple(attr.data_type, attr.data)
            return Color(argb) if argb else None
        return None

    def _renderables_from_res_id(self, res_id: int) -> list[Renderable]:
        out: list[Renderable] = []
        seen: set[tuple[str, str]] = set()
        for value in self.table.resolve(res_id):
            result = self._renderable_from_value(value)
            if not isinstance(result, (Raster, Vector, Composite)):
                continue
            key = (type(result).__name__, result.name)
            if key in seen:
                continue
            seen.add(key)
            out.append(result)
        return out

    def _best_from_res_id(self, res_id: int) -> Renderable | None:
        candidates = self._renderables_from_res_id(res_id)
        colors: list[Color] = []
        for value in self.table.resolve(res_id):
            if TYPE_FIRST_COLOR_INT <= value.data_type <= TYPE_LAST_COLOR_INT:
                argb = color_tuple(value.data_type, value.data)
                if argb:
                    colors.append(Color(argb))
        if candidates:
            prio = {Composite: 4, Vector: 3, Raster: 2}
            candidates.sort(
                key=lambda c: (
                    prio.get(type(c), 0),
                    self._path_score(c.name),
                    len(c.data) if isinstance(c, Raster) else 0,
                ),
                reverse=True,
            )
            return candidates[0]
        return colors[0] if colors else None

    def icon_candidates(self) -> list[Renderable]:
        results: list[Renderable] = []
        seen: set[tuple[str, str]] = set()

        def add_all(res_id: int) -> None:
            for renderable in self._renderables_from_res_id(res_id):
                key = (type(renderable).__name__, renderable.name)
                if key not in seen:
                    seen.add(key)
                    results.append(renderable)

        for res_id in self.manifest_icon_ids():
            add_all(res_id)
        if not results:
            for res_id in self.named_icon_ids():
                add_all(res_id)
                if len(results) >= 24:
                    break
        prio = {Composite: 4, Vector: 3, Raster: 2}
        results.sort(
            key=lambda c: (
                prio.get(type(c), 0),
                self._path_score(c.name),
                len(c.data) if isinstance(c, Raster) else 0,
            ),
            reverse=True,
        )
        return results


# --------------------------------------------------------------------------- #
# rendering
# --------------------------------------------------------------------------- #

RENDER_SIZE = 512
ADAPTIVE_SAFE_ZONE = 72 / 108


def _magick_binary() -> str:
    for name in ("magick", "convert"):
        path = shutil.which(name)
        if path:
            return path
    raise RuntimeError("ImageMagick is required to rasterise launcher icons (install 'magick' or 'convert')")


def _run(magick: str, *args: str) -> None:
    result = subprocess.run([magick, *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"ImageMagick failed: {' '.join(args)}")


def _render_node(
    node: Raster | Vector | Composite | Color,
    workdir: Path,
    magick: str,
    xml_loader=None,
    name: str = "icon",
) -> Path:
    """Render one drawable layer to a square 512px PNG."""

    if isinstance(node, Color):
        r, g, b, a = node.rgba
        out = workdir / f"{name}-color.png"
        _run(magick, "-size", f"{RENDER_SIZE}x{RENDER_SIZE}", f"xc:rgba({r},{g},{b},{a / 255:.4f})", str(out))
        return out

    if isinstance(node, Raster):
        source = workdir / f"{name}-source.img"
        source.write_bytes(node.data)
        out = workdir / f"{name}-raster.png"
        _run(
            magick,
            str(source),
            "-background",
            "none",
            "-gravity",
            "center",
            "-resize",
            f"{RENDER_SIZE}x{RENDER_SIZE}",
            "-extent",
            f"{RENDER_SIZE}x{RENDER_SIZE}",
            str(out),
        )
        return out

    if isinstance(node, Vector):
        source = workdir / f"{name}-vector.svg"
        source.write_text(vector_to_svg(node, RENDER_SIZE, xml_loader), encoding="utf-8")
        out = workdir / f"{name}-vector.png"
        _run(magick, "-background", "none", str(source), str(out))
        return out

    if isinstance(node, Composite):
        foreground = _render_node(node.foreground, workdir, magick, xml_loader, f"{name}-fg")
        if isinstance(node.background, Color):
            background = _render_node(node.background, workdir, magick, xml_loader, f"{name}-bg")
        elif isinstance(node.background, (Raster, Vector)):
            background = _render_node(node.background, workdir, magick, xml_loader, f"{name}-bg")
        else:
            background = workdir / f"{name}-bg.png"
            _run(magick, "-size", f"{RENDER_SIZE}x{RENDER_SIZE}", "xc:white", str(background))
        out = workdir / f"{name}-composite.png"
        _run(
            magick,
            str(background),
            "-colorspace",
            "sRGB",
            str(foreground),
            "-colorspace",
            "sRGB",
            "-gravity",
            "center",
            "-compose",
            "over",
            "-composite",
            str(out),
        )
        return out

    raise TypeError(f"unsupported renderable: {type(node).__name__}")


def render_to_png(
    renderable: Renderable,
    output: Path,
    size: int = 96,
    xml_loader=None,
) -> Path:
    """Render a launcher icon to ``size``px, cut to a circle.

    Adaptive icons are cropped to their 72/108 safe zone first, matching how a
    round launcher mask displays them.  Legacy square icons are cropped to a
    circle without shrinking their artwork.
    """

    magick = _magick_binary()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="apk-icon-") as tmp:
        workdir = Path(tmp)
        rendered = _render_node(renderable, workdir, magick, xml_loader)
        ratio = ADAPTIVE_SAFE_ZONE if isinstance(renderable, Composite) else 1.0
        crop = max(1, round(RENDER_SIZE * ratio))
        square = workdir / "square.png"
        _run(
            magick,
            str(rendered),
            "-gravity",
            "center",
            "-crop",
            f"{crop}x{crop}+0+0",
            "+repage",
            "-resize",
            f"{size}x{size}",
            str(square),
        )
        supersample = size * 4
        mask = workdir / "mask.png"
        _run(
            magick,
            "-size",
            f"{supersample}x{supersample}",
            "xc:none",
            "-fill",
            "white",
            "-draw",
            f"circle {supersample // 2},{supersample // 2} {supersample // 2},0",
            "-resize",
            f"{size}x{size}",
            str(mask),
        )
        _run(
            magick,
            str(square),
            str(mask),
            "-alpha",
            "off",
            "-compose",
            "CopyOpacity",
            "-composite",
            str(output),
        )
    return output
