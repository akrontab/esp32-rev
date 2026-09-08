#!/usr/bin/env python3
"""Prepare an ESP32 app image for Ghidra: dump each segment to a raw file and
emit a memory map, so Ghidra can load segments at their real addresses instead
of as one flat, mis-based blob.

Reuses espfmt (already validated against esptool) to read the image header and
segments. Chooses the Ghidra language from the chip family.

Writes:
  reports/ghidra/seg_<i>_<addr>.bin   one file per segment
  reports/ghidra/segments.json        {language, entry, primary, segments[...]}
"""

import json
import os
import sys

import espfmt

WORK = os.environ.get("WORK", "/work")
OUT = os.path.join(WORK, "reports", "ghidra")

# Ghidra 12 ships these natively. Xtensa covers the classic ESP32 + S2/S3;
# RISC-V covers C3/C6/H2. Exact ids verified against the installed Ghidra.
XTENSA = "Xtensa:LE:32:default"
RISCV = "RISCV:LE:32:default"

RISCV_CHIPS = {"esp32c2", "esp32c3", "esp32c5", "esp32c6", "esp32c61", "esp32h2", "esp32h4"}


def pick_language(chip_arg):
    c = (chip_arg or "").lower().replace("-", "")
    if c in RISCV_CHIPS:
        return RISCV
    return XTENSA          # esp32 / s2 / s3 and unknown -> Xtensa


def executable(load_addr):
    # IRAM/IROM ranges on ESP32 parts are the executable ones.
    return (0x40000000 <= load_addr <= 0x403FFFFF or   # Xtensa IRAM/IROM (classic + S3)
            0x42000000 <= load_addr <= 0x44000000 or   # S3 IROM (mmap)
            0x40800000 <= load_addr <= 0x40880000)      # RISC-V IRAM


def main():
    img_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORK, "parts", "app0.bin")
    if not os.path.isfile(img_path):
        print("[x] app image not found: %s" % img_path, file=sys.stderr)
        print("    Run the analysis pipeline first (split) to produce parts/app0.bin.", file=sys.stderr)
        return 1

    data = open(img_path, "rb").read()
    img = espfmt.parse_image(data)
    if not img.magic_ok or not img.segments:
        print("[x] not a valid ESP image (or encrypted): %s" % img_path, file=sys.stderr)
        return 1

    # Read chip from meta if available, else from the image header.
    chip_arg = ""
    meta = os.path.join(WORK, "meta", "target.json")
    if os.path.isfile(meta):
        try:
            chip_arg = json.load(open(meta)).get("chip_arg", "")
        except (ValueError, OSError):
            pass
    if not chip_arg:
        chip_arg = img.chip.lower().replace("-", "").split()[0]

    language = pick_language(chip_arg)
    os.makedirs(OUT, exist_ok=True)

    segs = []
    primary = 0
    for i, s in enumerate(img.segments):
        blob = data[s.file_offset:s.file_offset + s.length]
        name = "seg_%d_%08x.bin" % (i, s.load_addr)
        with open(os.path.join(OUT, name), "wb") as fh:
            fh.write(blob)
        is_exec = executable(s.load_addr)
        # The segment holding the entry point is the natural one to import first.
        if s.load_addr <= img.entry_addr < s.load_addr + s.length:
            primary = i
        segs.append({
            "index": i, "file": name, "base": s.load_addr,
            "length": s.length, "exec": is_exec,
        })

    manifest = {
        "language": language,
        "chip": chip_arg,
        "entry": img.entry_addr,
        "primary": primary,
        "image": os.path.basename(img_path),
        "segments": segs,
    }
    with open(os.path.join(OUT, "segments.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)

    # Plain TSV for the Ghidra Java scripts (no JSON lib needed there):
    #   index  base(hex)  length  exec(0/1)  file  primary(0/1)
    with open(os.path.join(OUT, "segments.tsv"), "w") as fh:
        for s in segs:
            fh.write("%d\t%08x\t%d\t%d\t%s\t%d\n" % (
                s["index"], s["base"], s["length"],
                1 if s["exec"] else 0, s["file"],
                1 if s["index"] == primary else 0))

    print("[+] %d segments -> reports/ghidra/  (language %s, entry 0x%08x)"
          % (len(segs), language, img.entry_addr))
    for s in segs:
        print("    seg%d base=0x%08x len=0x%-6x %s%s"
              % (s["index"], s["base"], s["length"],
                 "exec" if s["exec"] else "data",
                 "  <- primary (entry)" if s["index"] == primary else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
