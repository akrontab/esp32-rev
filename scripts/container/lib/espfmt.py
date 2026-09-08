"""
Parsers for the on-flash formats used by ESP-IDF / Arduino-ESP32 firmware.

Written from the documented structures (esp_image_format.h, esp_app_format.h,
esp_partition.h) so that analysis has no network or SDK dependency. Every
parser is tolerant: it returns what it could read and flags what looked wrong,
because a CTF dump is often truncated, encrypted or deliberately mangled.
"""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field, asdict
from typing import Optional

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

IMAGE_MAGIC = 0xE9
APP_DESC_MAGIC = 0xABCD5432
PART_MAGIC = 0x50AA
PART_MD5_MAGIC = 0xEBEB
PART_TABLE_OFFSET = 0x8000
PART_TABLE_SIZE = 0x1000
PART_ENTRY_SIZE = 32

# Bootloader offset differs by target: the older Xtensa parts reserve room the
# newer RISC-V parts do not.
BOOTLOADER_OFFSET = {
    "esp32": 0x1000, "esp32s2": 0x1000, "esp32p4": 0x2000,
    "esp32s3": 0x0, "esp32c3": 0x0, "esp32c2": 0x0,
    "esp32c6": 0x0, "esp32h2": 0x0, "esp32c5": 0x0, "esp32c61": 0x0,
}

CHIP_IDS = {
    0x0000: "ESP32", 0x0002: "ESP32-S2", 0x0005: "ESP32-C3",
    0x0009: "ESP32-S3", 0x000C: "ESP32-C2", 0x000D: "ESP32-C6",
    0x0010: "ESP32-H2", 0x0012: "ESP32-P4", 0xFFFF: "invalid/any",
}

FLASH_MODES = {0: "QIO", 1: "QOUT", 2: "DIO", 3: "DOUT", 4: "FAST_READ", 5: "SLOW_READ"}
FLASH_SIZES = {0: "1MB", 1: "2MB", 2: "4MB", 3: "8MB", 4: "16MB", 5: "32MB", 6: "64MB", 7: "128MB"}
FLASH_FREQS = {0x0: "40MHz", 0x1: "26MHz", 0x2: "20MHz", 0xF: "80MHz"}

SIZE_TO_BYTES = {
    "256KB": 256 * 1024, "512KB": 512 * 1024,
    "1MB": 1 << 20, "2MB": 2 << 20, "4MB": 4 << 20, "8MB": 8 << 20,
    "16MB": 16 << 20, "32MB": 32 << 20, "64MB": 64 << 20, "128MB": 128 << 20,
}

PART_TYPES = {0x00: "app", 0x01: "data"}
_APP_SUBTYPES = {0x00: "factory", 0x20: "test"}
_APP_SUBTYPES.update({0x10 + i: "ota_%d" % i for i in range(16)})
PART_SUBTYPES = {
    0x00: _APP_SUBTYPES,
    0x01: {0x00: "otadata", 0x01: "phy", 0x02: "nvs", 0x03: "coredump",
           0x04: "nvs_keys", 0x05: "efuse_em", 0x06: "undefined",
           0x80: "esphttpd", 0x81: "fat", 0x82: "spiffs", 0x83: "littlefs"},
}


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

ENTROPY_SAMPLE = 1 << 20      # 1 MiB is ample to characterise a region


def byte_counts(data: bytes) -> list:
    """Histogram of byte values.

    bytes.count() runs in C, so 256 passes beat one Python-level loop over the
    data by a wide margin - which matters when the caller is sweeping an 8 MB
    dump rather than a toy fixture.
    """
    return [data.count(i) for i in range(256)]


def entropy(data: bytes, sample: int = ENTROPY_SAMPLE) -> float:
    """Shannon entropy in bits/byte. Near 8.0 means encrypted or compressed."""
    if not data:
        return 0.0
    if sample and len(data) > sample:
        data = data[:sample]
    n = len(data)
    counts = byte_counts(data)
    return -sum((c / n) * math.log2(c / n) for c in counts if c)


def xor_all(data: bytes) -> int:
    """XOR of every byte, via the histogram.

    A value XORed an even number of times cancels, so only bytes with an odd
    count contribute. That turns an N-step Python loop into 256 C-level
    passes - the ESP image checksum covers megabytes of segment data.
    """
    x = 0
    for value, count in enumerate(byte_counts(data)):
        if count & 1:
            x ^= value
    return x


def cstr(raw: bytes) -> str:
    """Decode a fixed-width NUL-padded C string, tolerating junk bytes."""
    return raw.split(b"\x00")[0].decode("utf-8", "replace").strip()


def looks_blank(data: bytes) -> bool:
    """True if the region is entirely erased flash or all zeroes."""
    if not data:
        return True
    s = set(data)
    return s <= {0xFF} or s <= {0x00}


# ---------------------------------------------------------------------------
# application / bootloader images
# ---------------------------------------------------------------------------

@dataclass
class Segment:
    index: int
    load_addr: int
    length: int
    file_offset: int          # absolute offset of segment data within the blob
    entropy: float = 0.0
    note: str = ""


@dataclass
class AppDescriptor:
    secure_version: int = 0
    version: str = ""
    project_name: str = ""
    time: str = ""
    date: str = ""
    idf_ver: str = ""
    elf_sha256: str = ""


@dataclass
class EspImage:
    offset: int
    magic_ok: bool
    segment_count: int = 0
    entry_addr: int = 0
    chip: str = ""
    chip_id: int = 0
    flash_mode: str = ""
    flash_size: str = ""
    flash_freq: str = ""
    hash_appended: bool = False
    min_chip_rev_full: int = 0
    image_length: int = 0
    checksum_ok: Optional[bool] = None
    sha256: str = ""
    segments: list = field(default_factory=list)
    app_desc: Optional[AppDescriptor] = None
    errors: list = field(default_factory=list)

    def to_dict(self):
        return asdict(self)


def parse_app_descriptor(data: bytes, off: int) -> Optional[AppDescriptor]:
    """esp_app_desc_t sits at offset 0x20 of an application image."""
    if off + 256 > len(data):
        return None
    magic, secure_version = struct.unpack_from("<II", data, off)
    if magic != APP_DESC_MAGIC:
        return None
    return AppDescriptor(
        secure_version=secure_version,
        version=cstr(data[off + 16:off + 48]),
        project_name=cstr(data[off + 48:off + 80]),
        time=cstr(data[off + 80:off + 96]),
        date=cstr(data[off + 96:off + 112]),
        idf_ver=cstr(data[off + 112:off + 144]),
        elf_sha256=data[off + 144:off + 176].hex(),
    )


def parse_image(data: bytes, offset: int = 0, verify: bool = True) -> EspImage:
    """Parse one esp_image_header_t plus its segments starting at `offset`."""
    img = EspImage(offset=offset, magic_ok=False)
    if offset + 24 > len(data):
        img.errors.append("truncated before header")
        return img

    magic, seg_count, spi_mode, spi_ss, entry = struct.unpack_from("<BBBBI", data, offset)
    if magic != IMAGE_MAGIC:
        img.errors.append("bad magic 0x%02X" % magic)
        return img
    img.magic_ok = True
    img.segment_count = seg_count
    img.entry_addr = entry
    img.flash_mode = FLASH_MODES.get(spi_mode, "0x%02X" % spi_mode)
    img.flash_size = FLASH_SIZES.get(spi_ss >> 4, "0x%X" % (spi_ss >> 4))
    img.flash_freq = FLASH_FREQS.get(spi_ss & 0xF, "0x%X" % (spi_ss & 0xF))

    chip_id, _min_rev, min_rev_full = struct.unpack_from("<HBH", data, offset + 12)
    img.chip_id = chip_id
    img.chip = CHIP_IDS.get(chip_id, "unknown (0x%04X)" % chip_id)
    img.min_chip_rev_full = min_rev_full
    img.hash_appended = bool(data[offset + 23])

    # A wildly high segment count means we are not really looking at an image.
    if not 0 < seg_count <= 16:
        img.errors.append("implausible segment count %d" % seg_count)
        return img

    pos = offset + 24
    for i in range(seg_count):
        if pos + 8 > len(data):
            img.errors.append("truncated in segment %d header" % i)
            return img
        load_addr, length = struct.unpack_from("<II", data, pos)
        pos += 8
        if length > (16 << 20) or pos + length > len(data):
            img.errors.append("segment %d length %d runs past end of data" % (i, length))
            img.segments.append(Segment(i, load_addr, length, pos, note="truncated"))
            return img
        img.segments.append(Segment(
            i, load_addr, length, pos,
            entropy=round(entropy(data[pos:pos + length]), 3)))
        pos += length

    # One checksum byte, positioned so the whole image is a multiple of 16.
    pad = 15 - ((pos - offset) % 16)
    checksum_pos = pos + pad
    if verify and checksum_pos < len(data):
        xor = 0xEF
        for seg in img.segments:
            xor ^= xor_all(data[seg.file_offset:seg.file_offset + seg.length])
        img.checksum_ok = (xor == data[checksum_pos])
    pos = checksum_pos + 1

    if img.hash_appended and pos + 32 <= len(data):
        img.sha256 = data[pos:pos + 32].hex()
        pos += 32

    img.image_length = pos - offset
    img.app_desc = parse_app_descriptor(data, offset + 0x20)
    return img


def find_images(data: bytes, step: int = 0x1000, limit: int = 64) -> list:
    """Scan sector-aligned offsets for plausible image headers.

    Used when the partition table is missing or unreadable, which happens on
    dumps that are encrypted, partial, or intentionally damaged.
    """
    found = []
    for off in range(0, max(0, len(data) - 24), step):
        if data[off] != IMAGE_MAGIC:
            continue
        img = parse_image(data, off, verify=False)
        # Require sane segments loading into real ESP address ranges, or we
        # drown in false positives from ordinary 0xE9 bytes.
        if img.magic_ok and img.segments and not img.errors:
            if any(0x3C000000 <= s.load_addr <= 0x60000000 for s in img.segments):
                found.append(img)
        if len(found) >= limit:
            break
    return found


# ---------------------------------------------------------------------------
# partition table
# ---------------------------------------------------------------------------

@dataclass
class Partition:
    index: int
    type_id: int
    subtype_id: int
    type: str
    subtype: str
    offset: int
    size: int
    label: str
    flags: int

    @property
    def encrypted(self) -> bool:
        return bool(self.flags & 0x1)

    @property
    def end(self) -> int:
        return self.offset + self.size


def parse_partition_table(data: bytes) -> tuple:
    """Parse a partition table blob. Returns (partitions, md5_hex_or_None).

    `data` may be the 0x1000 table region alone, or a whole flash dump - in the
    latter case the table is read from the standard 0x8000 offset.
    """
    if len(data) > PART_TABLE_SIZE:
        blob = data[PART_TABLE_OFFSET:PART_TABLE_OFFSET + PART_TABLE_SIZE]
    else:
        blob = data

    parts, md5 = [], None
    for i in range(len(blob) // PART_ENTRY_SIZE):
        raw = blob[i * PART_ENTRY_SIZE:(i + 1) * PART_ENTRY_SIZE]
        magic = struct.unpack_from("<H", raw)[0]
        if magic == PART_MD5_MAGIC:
            md5 = raw[16:32].hex()
            continue
        if magic != PART_MAGIC:
            break                      # end of table (0xFF padding) or garbage
        type_id, subtype_id = raw[2], raw[3]
        offset, size = struct.unpack_from("<II", raw, 4)
        parts.append(Partition(
            index=len(parts),
            type_id=type_id,
            subtype_id=subtype_id,
            type=PART_TYPES.get(type_id, "0x%02X" % type_id),
            subtype=PART_SUBTYPES.get(type_id, {}).get(subtype_id, "0x%02X" % subtype_id),
            offset=offset,
            size=size,
            label=cstr(raw[12:28]),
            flags=struct.unpack_from("<I", raw, 28)[0],
        ))
    return parts, md5


def partition_table_ok(blob: bytes) -> bool:
    return len(blob) >= 2 and struct.unpack_from("<H", blob)[0] == PART_MAGIC
