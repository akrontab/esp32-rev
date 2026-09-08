"""Reader for SPIFFS images as produced by ESP-IDF.

SPIFFS has no directory structure - it is a flat set of objects, each made of
one index page listing the data pages that hold its contents. We read it by
sweeping every page rather than following the filesystem's own bookkeeping,
which means a damaged or partially overwritten image still yields whatever
remains intact. Deleted files are reported too: SPIFFS only clears a flag bit,
so their contents usually survive until the block is garbage-collected, and on
a CTF badge a deleted file is very often the point.

Layout (spiffs_config.h defaults used by ESP-IDF):
  page header  : obj_id u16, span_ix u16, flags u8
  index page   : header, pad to 8, size u32, type u8, name[32], meta[4],
                 pad to 2-byte alignment, then u16 page indices
  data page    : header, then (page_size - 5) content bytes
  flags are active-low: bit0 USED, bit1 FINAL, bit2 INDEX, bit7 DELETED
"""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field

FLAG_USED = 0x01
FLAG_FINAL = 0x02
FLAG_INDEX = 0x04
FLAG_DELETED = 0x80

OBJ_ID_FREE = 0xFFFF
IX_FLAG = 0x8000


class SpiffsConfig:
    """Geometry of the image. The defaults match ESP-IDF's out-of-the-box
    SPIFFS; a badge that changed sdkconfig needs the overrides."""

    def __init__(self, page_size=256, block_size=4096, obj_name_len=32, meta_len=4):
        self.page_size = page_size
        self.block_size = block_size
        self.obj_name_len = obj_name_len
        self.meta_len = meta_len

        self.pages_per_block = block_size // page_size
        self.lu_pages_per_block = int(math.ceil(
            self.pages_per_block * 2 / float(page_size)))

        self.data_hdr_len = 5                       # obj_id + span_ix + flags
        self.data_content_len = page_size - self.data_hdr_len

        # The index page pads its header out to a 4-byte boundary.
        pad = 4 - (4 if self.data_hdr_len % 4 == 0 else self.data_hdr_len % 4)
        self.hdr_aligned = self.data_hdr_len + pad   # 8

        raw = self.hdr_aligned + 4 + 1 + obj_name_len + meta_len
        self.ix_header_len = (raw + 1) & ~1          # align to u16
        self.name_off = self.hdr_aligned + 4 + 1


@dataclass
class SpiffsFile:
    obj_id: int
    name: str
    size: int
    obj_type: int
    index_page: int
    deleted: bool = False
    data: bytes = b""
    complete: bool = True
    note: str = ""


@dataclass
class SpiffsScan:
    config: SpiffsConfig
    files: list = field(default_factory=list)
    orphan_pages: int = 0
    total_pages: int = 0
    used_pages: int = 0


def _is_lookup_page(page_index: int, cfg: SpiffsConfig) -> bool:
    return (page_index % cfg.pages_per_block) < cfg.lu_pages_per_block


def scan(data: bytes, cfg: SpiffsConfig = None) -> SpiffsScan:
    cfg = cfg or SpiffsConfig()
    result = SpiffsScan(config=cfg)

    index_pages = {}      # obj_id (without IX flag) -> (page_index, meta)
    data_pages = {}       # obj_id -> {span_ix: content}

    n_pages = len(data) // cfg.page_size
    result.total_pages = n_pages

    for pi in range(n_pages):
        if _is_lookup_page(pi, cfg):
            continue
        off = pi * cfg.page_size
        page = data[off:off + cfg.page_size]
        if len(page) < cfg.data_hdr_len:
            continue

        obj_id, span_ix, flags = struct.unpack_from("<HHB", page, 0)
        if obj_id == OBJ_ID_FREE:
            continue
        if flags & FLAG_USED:            # bit set means never written
            continue
        result.used_pages += 1
        deleted = not (flags & FLAG_DELETED)

        if not (flags & FLAG_INDEX):
            # Index page. Only span 0 carries the name and size.
            base_id = obj_id & ~IX_FLAG
            if span_ix != 0:
                continue
            if off + cfg.ix_header_len > len(data):
                continue
            size, obj_type = struct.unpack_from("<IB", page, cfg.hdr_aligned)
            name_raw = page[cfg.name_off:cfg.name_off + cfg.obj_name_len]
            name = name_raw.split(b"\x00")[0].decode("utf-8", "replace")
            index_pages[base_id] = (pi, size, obj_type, name, deleted)
        else:
            content = page[cfg.data_hdr_len:cfg.data_hdr_len + cfg.data_content_len]
            data_pages.setdefault(obj_id & ~IX_FLAG, {})[span_ix] = content

    for base_id, (pi, size, obj_type, name, deleted) in sorted(index_pages.items()):
        chunks = data_pages.get(base_id, {})
        blob = b""
        expected_spans = int(math.ceil(size / float(cfg.data_content_len))) if size else 0
        missing = []
        for span in range(expected_spans):
            if span in chunks:
                blob += chunks[span]
            else:
                missing.append(span)
                blob += b"\x00" * cfg.data_content_len
        blob = blob[:size]

        f = SpiffsFile(
            obj_id=base_id, name=name, size=size, obj_type=obj_type,
            index_page=pi, deleted=deleted, data=blob,
            complete=not missing,
        )
        if missing:
            f.note = "missing %d of %d data pages (zero-filled)" % (len(missing), expected_spans)
        result.files.append(f)

    accounted = set(index_pages)
    result.orphan_pages = sum(len(v) for k, v in data_pages.items() if k not in accounted)
    return result


def looks_like_spiffs(data: bytes, cfg: SpiffsConfig = None) -> bool:
    """Cheap probe: does a sweep find at least one plausible named object?"""
    cfg = cfg or SpiffsConfig()
    if len(data) < cfg.block_size:
        return False
    try:
        found = scan(data[:min(len(data), 64 * cfg.block_size)], cfg)
    except Exception:
        return False
    return any(f.name for f in found.files)
