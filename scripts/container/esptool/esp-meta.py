#!/usr/bin/env python3
"""Distil esptool's human-readable probe output into meta/target.json.

esptool has no stable machine-readable output, so we scrape it. Everything is
best-effort: a missing field means the chip did not report it, which is itself
worth knowing (a read-protected or secure-booted part answers fewer queries).
"""

import json
import os
import re
import sys

META = os.path.join(os.environ.get("WORK", "/work"), "meta")

PATTERNS = {
    # esptool 5.x prints "Chip type:          ESP32-D0WD-V3 (revision v3.1)".
    # The 4.x spelling ("Chip is ...") is kept as an alternative so a pinned
    # older esptool still parses.
    "chip_model":    r"(?:Chip type:|Chip is)\s+([^\s(]+)",
    "chip_revision": r"(?:Chip type:|Chip is)\s+\S+\s+\(revision\s+([^)]+)\)",
    # "Detecting chip type...ESP32-S3" - printed with end="" so the value
    # lands on the same line.
    "chip_family":   r"Detecting chip type\.\.\.\s*(\S+)",
    "features":      r"Features:\s*(.+)",
    "crystal":       r"(?:Crystal frequency:|Crystal is)\s*(\S+)",
    "usb_mode":      r"USB mode:\s*(.+)",
    "mac":           r"(?:MAC|BASE MAC):\s*([0-9a-fA-F:]{17})",
    "flash_size":    r"Detected flash size:\s*(\S+)",
    "flash_mfr":     r"Manufacturer:\s*([0-9a-fA-F]+)",
    "flash_device":  r"Device:\s*([0-9a-fA-F]+)",
    "flash_type":    r"Flash type set in eFuse:\s*(\S+)",
    "secure_boot":   r"Secure Boot:\s*(.+)",
    "flash_enc":     r"Flash Encryption:\s*(.+)",
    "sec_flags":     r"Flags:\s*(.+)",
}

# Phrases that mean protection is switched on. Presence of any of these is a
# hard signal that a plain serial flash read will not give usable plaintext.
LOCK_HINTS = [
    ("flash_encryption_enabled", r"Flash Encryption:\s*(Enabled|Yes)"),
    ("secure_boot_enabled",      r"Secure Boot:\s*(Enabled|Yes)"),
    ("download_mode_disabled",   r"Download Mode:\s*(Disabled)"),
    # esptool announces this on the chip-type line. It means most commands,
    # including any flash read, will be refused - the single most important
    # thing to notice early.
    ("secure_download_mode",     r"in Secure Download Mode"),
]


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(META, "esptool_detect.txt")
    try:
        text = open(src, encoding="utf-8", errors="replace").read()
    except OSError as e:
        print("cannot read %s: %s" % (src, e), file=sys.stderr)
        return 1

    out = {"source": os.path.basename(src)}
    for key, pat in PATTERNS.items():
        m = re.search(pat, text)
        if m:
            out[key] = m.group(1).strip()

    # Normalise the family into the identifier esptool's --chip flag expects,
    # so later commands can pin the chip instead of re-detecting every time.
    fam = out.get("chip_family") or out.get("chip_model") or ""
    norm = fam.lower().replace("-", "").split("(")[0].strip()
    if norm.startswith("esp"):
        out["chip_arg"] = norm

    for name, pat in LOCK_HINTS:
        out[name] = bool(re.search(pat, text, re.I))

    # Flash size as bytes is what the dump step actually needs.
    size = out.get("flash_size", "")
    mult = {"KB": 1024, "MB": 1024 * 1024}
    m = re.match(r"(\d+)(KB|MB)$", size)
    if m:
        out["flash_bytes"] = int(m.group(1)) * mult[m.group(2)]

    os.makedirs(META, exist_ok=True)
    dest = os.path.join(META, "target.json")
    with open(dest, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)

    print()
    print("=== target summary ===")
    for k in ("chip_model", "chip_revision", "chip_arg", "features", "crystal",
              "usb_mode", "mac", "flash_size", "flash_mfr", "flash_device"):
        if out.get(k):
            print("  %-14s %s" % (k + ":", out[k]))
    locked = [n for n, _ in LOCK_HINTS if out.get(n)]
    if locked:
        print("  protection:    " + ", ".join(locked))
        print("  NOTE: a raw flash read will be ciphertext or may be refused.")
    else:
        print("  protection:    none detected - plain flash read should work")
    print("  written to     meta/target.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
