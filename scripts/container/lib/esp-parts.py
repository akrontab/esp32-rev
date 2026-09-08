#!/usr/bin/env python3
"""Decode an ESP partition table into a report and machine-readable JSON.

Accepts either the 4 KiB table region or a whole flash dump. Shared by both
images: the hardware side runs it on a freshly read table, the analysis side
runs it on the dump.
"""

import json
import os
import sys

import espfmt

WORK = os.environ.get("WORK", "/work")


def main():
    if len(sys.argv) < 2:
        print("usage: esp-parts.py <partition-table.bin|flash_full.bin>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        data = open(path, "rb").read()
    except OSError as e:
        print("cannot read %s: %s" % (path, e), file=sys.stderr)
        return 1

    parts, md5 = espfmt.parse_partition_table(data)
    if not parts:
        print("[x] No valid partition table found.")
        print("    Expected magic 0xAA50 at offset 0x8000 (or at the start of a table blob).")
        print("    If the dump is encrypted this is exactly what you would see.")
        return 1

    lines = []
    lines.append("%-4s %-16s %-5s %-9s %-10s %-10s %-9s %s"
                 % ("#", "label", "type", "subtype", "offset", "size", "size_kb", "flags"))
    lines.append("-" * 88)
    for p in parts:
        lines.append("%-4d %-16s %-5s %-9s 0x%08x 0x%08x %-9d %s"
                     % (p.index, p.label, p.type, p.subtype, p.offset, p.size,
                        p.size // 1024, "encrypted" if p.encrypted else ""))

    total = max(p.end for p in parts)
    lines.append("")
    lines.append("highest partition end: 0x%08x (%d KiB) - flash must be at least this big"
                 % (total, total // 1024))
    if md5:
        lines.append("table md5: %s" % md5)

    # Point at what is worth carving, so the next step is obvious.
    interesting = [p for p in parts if p.subtype in ("spiffs", "littlefs", "fat", "nvs")]
    if interesting:
        lines.append("")
        lines.append("carve candidates:")
        for p in interesting:
            lines.append("  %-16s %-9s 0x%08x +0x%x" % (p.label, p.subtype, p.offset, p.size))

    report = "\n".join(lines)
    print(report)

    os.makedirs(os.path.join(WORK, "reports"), exist_ok=True)
    os.makedirs(os.path.join(WORK, "meta"), exist_ok=True)
    with open(os.path.join(WORK, "reports", "partitions.txt"), "w", encoding="utf-8") as fh:
        fh.write(report + "\n")
    with open(os.path.join(WORK, "meta", "partitions.json"), "w", encoding="utf-8") as fh:
        json.dump([{
            "index": p.index, "label": p.label, "type": p.type, "subtype": p.subtype,
            "type_id": p.type_id, "subtype_id": p.subtype_id,
            "offset": p.offset, "size": p.size, "flags": p.flags,
            "encrypted": p.encrypted,
        } for p in parts], fh, indent=2)

    print()
    print("[+] wrote reports/partitions.txt and meta/partitions.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
