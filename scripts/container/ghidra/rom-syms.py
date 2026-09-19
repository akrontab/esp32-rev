#!/usr/bin/env python3
"""Convert Espressif ROM linker scripts into an address->name table for Ghidra.

Every ESP32 part has a mask ROM full of functions (libc, crypto, boot helpers)
living at fixed addresses. Espressif ships their names in `.rom.ld` linker
scripts inside ESP-IDF, as lines like:

    PROVIDE ( ets_printf = 0x40007d54 );

A stripped app image calls straight into those addresses, so Ghidra shows the
calls as `FUN_40007d54`. Feeding it these names turns hundreds of anonymous ROM
calls into `ets_printf`, `esp_rom_crc32_le`, `memcpy`, ... - so the functions
left unnamed are the app's own code, which is what you actually want to read.

Point it at the ld files from your IDF install for the badge's chip, e.g.:
    esp-idf/components/esp_rom/<chip>/ld/<chip>.rom*.ld

Usage:
    rom-syms.py <file-or-dir> [more...]        # writes rom-symbols.tsv
    rom-syms.py --out path.tsv <files...>

Writes reports/ghidra/rom-symbols.tsv (address<TAB>name), which Enrich.java
applies during headless analysis. Pure text; runs on the host or in-container.
"""

import os
import re
import sys

WORK = os.environ.get("WORK", "/work")

PROVIDE = re.compile(r"\bPROVIDE\s*\(\s*([A-Za-z_]\w*)\s*=\s*(0x[0-9a-fA-F]+)\s*\)")


def ld_files(paths):
    """Expand directories to the *.ld files inside them."""
    for p in paths:
        if os.path.isdir(p):
            for name in sorted(os.listdir(p)):
                if name.endswith(".ld"):
                    yield os.path.join(p, name)
        elif os.path.isfile(p):
            yield p
        else:
            print("[!] not found: %s" % p, file=sys.stderr)


def main():
    args = sys.argv[1:]
    out = None
    if "--out" in args:
        i = args.index("--out")
        out = args[i + 1]
        del args[i:i + 2]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if not out:
        out = os.path.join(os.environ.get("GHIDRA_OUT") or os.path.join(WORK, "reports", "ghidra"),
                           "rom-symbols.tsv")

    syms = {}                       # addr(int) -> name  (first name wins per addr)
    files = 0
    for f in ld_files(args):
        files += 1
        try:
            text = open(f, encoding="utf-8", errors="replace").read()
        except OSError as e:
            print("[!] %s: %s" % (f, e), file=sys.stderr)
            continue
        for name, addr in PROVIDE.findall(text):
            a = int(addr, 16)
            syms.setdefault(a, name)

    if not syms:
        print("[x] no PROVIDE(...) symbols found in %d file(s)." % files, file=sys.stderr)
        print("    Point at the chip's .rom.ld files, e.g. "
              "esp-idf/components/esp_rom/<chip>/ld/", file=sys.stderr)
        return 1

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        for a in sorted(syms):
            fh.write("%08x\t%s\n" % (a, syms[a]))

    rel = os.path.relpath(out, WORK) if out.startswith(WORK) else out
    print("[+] %d ROM symbols from %d file(s) -> %s" % (len(syms), files, rel))
    print("    Enrich.java applies these during [33]/[36]; re-run the analysis to pick them up.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
