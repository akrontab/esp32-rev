"""Reader for ESP-IDF NVS (non-volatile storage) partitions.

NVS is where an ESP application keeps its key/value configuration: WiFi
credentials, provisioning tokens, device identity, feature flags - and on a
CTF badge, very often the flag itself or the material needed to derive it. It
survives reflashing of the app partition, so it is usually the highest-value
region in a dump after the app image.

Layout (from nvs_flash/src/nvs_page.hpp):
  page       = 4096 bytes
  page[0:32] = header: state u32, seq_no u32, version u8, unused[19], crc32
  page[32:64]= entry state bitmap, 2 bits per entry, 126 entries
  page[64:]  = 126 entries of 32 bytes

Entry:
  ns_index u8, type u8, span u8, chunk_index u8, crc32 u32, key char[16],
  then 8 bytes that are either the primitive value, or for variable-length
  items: size u16, reserved u16, data crc32 u32 - with the payload living in
  the following (span - 1) entry slots.

Erased and overwritten items are left in place until the page is compacted, so
we also surface entries whose state is 'erased': stale secrets are still
readable and are frequently the intended find.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field

PAGE_SIZE = 4096
ENTRY_SIZE = 32
ENTRIES_PER_PAGE = 126
BITMAP_OFF = 32
ENTRY_OFF = 64

PAGE_STATES = {
    0xFFFFFFFF: "uninitialized",
    0xFFFFFFFE: "active",
    0xFFFFFFFC: "full",
    0xFFFFFFF8: "freeing",
    0xFFFFFFF0: "corrupt",
}

ENTRY_STATES = {0b11: "empty", 0b10: "written", 0b00: "erased", 0b01: "invalid"}

TYPES = {
    0x01: "u8", 0x11: "i8", 0x02: "u16", 0x12: "i16",
    0x04: "u32", 0x14: "i32", 0x08: "u64", 0x18: "i64",
    0x21: "str", 0x41: "blob", 0x42: "blob_data", 0x48: "blob_idx",
    0xFF: "any",
}

PRIMITIVE_FMT = {
    "u8": "<B", "i8": "<b", "u16": "<H", "i16": "<h",
    "u32": "<I", "i32": "<i", "u64": "<Q", "i64": "<q",
}

VARIABLE = ("str", "blob", "blob_data")


@dataclass
class NvsEntry:
    page_index: int
    entry_index: int
    state: str
    ns_index: int
    type: str
    type_id: int
    span: int
    chunk_index: int
    key: str
    value: object = None
    raw: bytes = b""
    namespace: str = ""
    note: str = ""


@dataclass
class NvsPage:
    index: int
    offset: int
    state: str
    seq_no: int
    version: int
    entries: list = field(default_factory=list)


def _entry_state(bitmap: bytes, i: int) -> str:
    """Two bits per entry, packed low-order first within each byte."""
    byte = bitmap[i // 4]
    bits = (byte >> ((i % 4) * 2)) & 0b11
    return ENTRY_STATES.get(bits, "invalid")


def _decode_key(raw: bytes) -> str:
    return raw.split(b"\x00")[0].decode("utf-8", "replace")


def parse_page(blob: bytes, page_index: int, offset: int) -> NvsPage:
    state, seq_no = struct.unpack_from("<II", blob, 0)
    version = blob[8]
    page = NvsPage(
        index=page_index,
        offset=offset,
        state=PAGE_STATES.get(state, "0x%08X" % state),
        seq_no=seq_no,
        version=version,
    )
    if page.state == "uninitialized":
        return page

    bitmap = blob[BITMAP_OFF:BITMAP_OFF + 32]

    i = 0
    while i < ENTRIES_PER_PAGE:
        est = _entry_state(bitmap, i)
        if est == "empty":
            i += 1
            continue

        base = ENTRY_OFF + i * ENTRY_SIZE
        raw = blob[base:base + ENTRY_SIZE]
        if len(raw) < ENTRY_SIZE:
            break

        ns_index, type_id, span, chunk_index = struct.unpack_from("<BBBB", raw, 0)
        key = _decode_key(raw[8:24])
        tname = TYPES.get(type_id, "0x%02X" % type_id)

        entry = NvsEntry(
            page_index=page_index, entry_index=i, state=est,
            ns_index=ns_index, type=tname, type_id=type_id,
            span=span, chunk_index=chunk_index, key=key, raw=raw[24:32],
        )

        if tname in PRIMITIVE_FMT:
            entry.value = struct.unpack_from(PRIMITIVE_FMT[tname], raw, 24)[0]
            i += 1

        elif tname in VARIABLE:
            size = struct.unpack_from("<H", raw, 24)[0]
            # Payload occupies the following entry slots, contiguous in-page.
            data_start = base + ENTRY_SIZE
            data = blob[data_start:data_start + size]
            if len(data) < size:
                entry.note = "payload truncated (crosses page end)"
            if tname == "str":
                entry.value = data.split(b"\x00")[0].decode("utf-8", "replace")
            else:
                entry.value = data
            # A sane span keeps us aligned; a corrupt one would desynchronise
            # the whole page, so fall back to computing it from the size.
            step = span if 1 <= span <= ENTRIES_PER_PAGE else 1 + (size + ENTRY_SIZE - 1) // ENTRY_SIZE
            i += step

        elif tname == "blob_idx":
            total, chunk_count, chunk_start = struct.unpack_from("<IBB", raw, 24)
            entry.value = {"total_size": total, "chunk_count": chunk_count,
                           "chunk_start": chunk_start}
            i += 1
        else:
            i += 1

        page.entries.append(entry)

    return page


def parse_nvs(data: bytes) -> list:
    """Parse a whole NVS partition into pages."""
    pages = []
    for pi in range(len(data) // PAGE_SIZE):
        off = pi * PAGE_SIZE
        pages.append(parse_page(data[off:off + PAGE_SIZE], pi, off))
    return pages


def resolve_namespaces(pages: list) -> dict:
    """Entries in namespace 0 map a namespace name to the index others use."""
    ns = {0: "<ns-table>"}
    for page in pages:
        for e in page.entries:
            if e.ns_index == 0 and e.type in PRIMITIVE_FMT and isinstance(e.value, int):
                ns[e.value] = e.key
    return ns


def collect(data: bytes) -> tuple:
    """Parse and annotate. Returns (pages, namespaces)."""
    pages = parse_nvs(data)
    ns = resolve_namespaces(pages)
    for page in pages:
        for e in page.entries:
            e.namespace = ns.get(e.ns_index, "ns#%d" % e.ns_index)
    return pages, ns


def looks_like_nvs(data: bytes) -> bool:
    """True only if the region holds at least one initialised NVS page.

    A blank partition is all 0xFF, which is a *valid* 'uninitialized' page
    state, so testing the first word alone matches every erased region on the
    flash. We require a page that has actually been used.
    """
    if len(data) < PAGE_SIZE:
        return False
    for pi in range(len(data) // PAGE_SIZE):
        off = pi * PAGE_SIZE
        state = struct.unpack_from("<I", data, off)[0]
        if PAGE_STATES.get(state) in ("active", "full", "freeing"):
            # Version byte is 0xFF (v1) or 0xFE (v2); anything else is chance.
            if data[off + 8] in (0xFE, 0xFF):
                return True
    return False
