#!/usr/bin/env python3
"""Split a flash dump into its partitions and classify each one.

Working on whole-dump offsets is error-prone and slow; every later step wants
a single partition. This carves parts/<label>.bin once and says what each
region actually contains, so you know where to spend your time.
"""

import json
import os
import sys

import espfmt
import nvsfmt
import spiffsfmt

WORK = os.environ.get("WORK", "/work")


def classify(blob: bytes) -> str:
    """Say what a partition really holds, regardless of its declared subtype -
    badges relabel partitions, and the subtype is only a hint."""
    if espfmt.looks_blank(blob):
        return "blank (erased or zeroed)"

    ent = espfmt.entropy(blob[:min(len(blob), 1 << 20)])

    if blob[:1] == bytes([espfmt.IMAGE_MAGIC]):
        img = espfmt.parse_image(blob)
        if img.magic_ok and img.segments:
            desc = img.app_desc
            extra = ""
            if desc and desc.project_name:
                extra = " '%s' v%s idf=%s" % (desc.project_name, desc.version, desc.idf_ver)
            return "ESP image, %d segments, %s%s" % (img.segment_count, img.chip, extra)

    if nvsfmt.looks_like_nvs(blob):
        return "NVS key/value store"

    if spiffsfmt.looks_like_spiffs(blob):
        return "SPIFFS filesystem"

    # LittleFS superblock marker sits in the first block.
    if b"littlefs" in blob[:8192]:
        return "LittleFS filesystem"

    if blob[510:512] == b"\x55\xaa" or b"FAT" in blob[:64]:
        return "FAT filesystem"

    if ent > 7.5:
        return "high entropy %.2f (encrypted or compressed)" % ent

    return "unrecognised (entropy %.2f)" % ent


def main():
    dump = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORK, "dumps", "flash_full.bin")
    if not os.path.isfile(dump):
        print("[x] No dump at %s - acquire one first." % dump, file=sys.stderr)
        return 1

    data = open(dump, "rb").read()
    parts, _md5 = espfmt.parse_partition_table(data)

    if not parts:
        print("[!] No partition table at 0x8000. Falling back to an image scan.")
        images = espfmt.find_images(data)
        if not images:
            print("[x] No ESP images found either. If entropy is high the dump is encrypted.")
            return 1
        for img in images:
            print("  image at 0x%08x  %s  %d segments" % (img.offset, img.chip, img.segment_count))
        print("\n[*] Carve manually with: dd if=dumps/flash_full.bin of=parts/x.bin bs=1 skip=... count=...")
        return 0

    outdir = os.path.join(WORK, "parts")
    os.makedirs(outdir, exist_ok=True)

    rows = []
    manifest = []
    for p in parts:
        blob = data[p.offset:p.end]
        if not blob:
            rows.append((p.label, p.subtype, p.offset, p.size, "beyond end of dump"))
            continue

        # Labels come off the badge; keep them from escaping the parts dir.
        safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in p.label) or ("part%d" % p.index)
        path = os.path.join(outdir, "%s.bin" % safe)
        with open(path, "wb") as fh:
            fh.write(blob)

        kind = classify(blob)
        short = len(blob) < p.size
        if short:
            kind += " [truncated: dump is smaller than the partition]"
        rows.append((p.label, p.subtype, p.offset, p.size, kind))
        manifest.append({
            "label": p.label, "file": "parts/%s.bin" % safe,
            "subtype": p.subtype, "offset": p.offset, "size": p.size,
            "bytes_written": len(blob), "classification": kind,
        })

    width = max(len(r[0]) for r in rows)
    print("%-*s %-9s %-10s %-9s %s" % (width, "label", "subtype", "offset", "size", "contents"))
    print("-" * 100)
    for label, subtype, off, size, kind in rows:
        print("%-*s %-9s 0x%08x %-9d %s" % (width, label, subtype, off, size, kind))

    with open(os.path.join(WORK, "meta", "parts_manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)

    print()
    print("[+] wrote %d partitions to parts/ and meta/parts_manifest.json" % len(manifest))
    return 0


if __name__ == "__main__":
    sys.exit(main())
