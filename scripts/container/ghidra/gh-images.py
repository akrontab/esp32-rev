#!/usr/bin/env python3
"""Enumerate every code-bearing ESP image inside a full flash dump.

The headless pipeline ([33], gh-analyze.sh) analyses one app image - normally
parts/app0.bin. A full flash dump holds more executable code than that: the
2nd-stage bootloader, and on OTA badges the other app slots (ota_1, factory).
This finds each loadable image so gh-dump.sh can run the same segment-accurate
Ghidra load over all of them.

Reuses espfmt (validated against esptool): parse_partition_table reads the
table straight from a whole dump, parse_image validates a header at any offset,
BOOTLOADER_OFFSET says where the bootloader lives per chip family.

Writes reports/ghidra/images.json - a list of every candidate with its offset,
image length, app descriptor, and whether it is loadable (with a reason when
not: blank slot, encrypted, or no valid header). Prints the same as a table.
Read-only: it never touches the dump beyond reading it.
"""

import json
import os
import sys

import espfmt

WORK = os.environ.get("WORK", "/work")
OUT = os.environ.get("GHIDRA_OUT") or os.path.join(WORK, "reports", "ghidra")

# Where a 2nd-stage bootloader can start, when the chip family is unknown.
BOOTLOADER_CANDIDATES = (0x0, 0x1000, 0x2000)


def norm_chip(c):
    return (c or "").lower().replace("-", "").split()[0]


def target_chip():
    """Chip family from the acquisition metadata, if the workspace has it."""
    meta = os.path.join(WORK, "meta", "target.json")
    if os.path.isfile(meta):
        try:
            return norm_chip(json.load(open(meta)).get("chip_arg", ""))
        except (ValueError, OSError):
            pass
    return ""


def image_entry(label, kind, offset, data):
    """Parse a candidate image and describe it (loadable or why not)."""
    img = espfmt.parse_image(data, offset=offset, verify=False)
    e = {
        "label": label, "kind": kind, "offset": offset,
        "loadable": False, "reason": "", "chip": "",
        "entry": 0, "image_length": 0, "segments": 0,
        "project_name": "", "idf_ver": "",
    }
    if not img.magic_ok:
        e["reason"] = "no image header (blank, data, or encrypted)"
        return e, img
    if not img.segments or img.errors:
        e["reason"] = img.errors[0] if img.errors else "no segments"
        return e, img
    e.update({
        "loadable": True,
        "chip": img.chip,
        "entry": img.entry_addr,
        "image_length": img.image_length,
        "segments": len(img.segments),
    })
    if img.app_desc:
        e["project_name"] = img.app_desc.project_name
        e["idf_ver"] = img.app_desc.idf_ver
    return e, img


def find_bootloader(data, chip):
    """Locate the 2nd-stage bootloader. Try the chip's fixed offset first,
    then the usual candidates - so it works even without target metadata."""
    tried = []
    off = espfmt.BOOTLOADER_OFFSET.get(chip)
    for cand in ([off] if off is not None else []) + list(BOOTLOADER_CANDIDATES):
        if cand is None or cand in tried:
            continue
        tried.append(cand)
        e, img = image_entry("bootloader", "bootloader", cand, data)
        if e["loadable"]:
            return e
    # Report the chip's expected offset as the failed candidate, if we have one.
    off = off if off is not None else BOOTLOADER_CANDIDATES[0]
    e, _ = image_entry("bootloader", "bootloader", off, data)
    return e


def main():
    dump = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORK, "dumps", "flash_full.bin")
    if not os.path.isfile(dump):
        print("[x] flash dump not found: %s" % dump, file=sys.stderr)
        print("    Acquire a full dump first ([9]/[10]) or point at dumps/flash_full.bin.",
              file=sys.stderr)
        return 1

    data = open(dump, "rb").read()
    os.makedirs(OUT, exist_ok=True)
    chip = target_chip()

    images = []

    # 1. Bootloader (not in the partition table; lives at a fixed low offset).
    boot = find_bootloader(data, chip)
    if not chip and boot["loadable"]:
        chip = norm_chip(boot["chip"])
    images.append(boot)

    # 2. App partitions from the on-flash partition table.
    parts, _md5 = espfmt.parse_partition_table(data)
    app_parts = [p for p in parts if p.type == "app"]
    if not parts:
        print("[!] No partition table at 0x8000 - scanning for images instead.",
              file=sys.stderr)
        for img in espfmt.find_images(data):
            e, _ = image_entry("img_%08x" % img.offset, "app", img.offset, data)
            images.append(e)
    else:
        for p in app_parts:
            label = p.label or p.subtype or ("app_%08x" % p.offset)
            blob = data[p.offset:p.end]
            if p.encrypted:
                images.append({"label": label, "kind": "app", "offset": p.offset,
                               "loadable": False, "reason": "partition flagged encrypted",
                               "chip": "", "entry": 0, "image_length": 0, "segments": 0,
                               "project_name": "", "idf_ver": ""})
                continue
            if espfmt.looks_blank(blob):
                images.append({"label": label, "kind": "app", "offset": p.offset,
                               "loadable": False, "reason": "blank slot (no image flashed)",
                               "chip": "", "entry": 0, "image_length": 0, "segments": 0,
                               "project_name": "", "idf_ver": ""})
                continue
            e, _ = image_entry(label, "app", p.offset, data)
            images.append(e)

    with open(os.path.join(OUT, "images.json"), "w") as fh:
        json.dump({"dump": os.path.basename(dump), "chip": chip, "images": images},
                  fh, indent=2)

    loadable = [i for i in images if i["loadable"]]
    print("[+] %d code image(s) in %s  (%d loadable)"
          % (len(images), os.path.basename(dump), len(loadable)))
    print("    %-12s %-11s %-10s %-8s %s" % ("label", "offset", "kind", "segs", "detail"))
    for i in images:
        if i["loadable"]:
            detail = "entry 0x%08x, %d bytes" % (i["entry"], i["image_length"])
            if i["project_name"]:
                detail += "  [%s, IDF %s]" % (i["project_name"], i["idf_ver"] or "?")
        else:
            detail = "skip: " + i["reason"]
        print("    %-12s 0x%08x  %-10s %-8s %s"
              % (i["label"], i["offset"], i["kind"],
                 i["segments"] if i["loadable"] else "-", detail))
    return 0


if __name__ == "__main__":
    sys.exit(main())
