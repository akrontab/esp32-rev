#!/usr/bin/env python3
"""Dump every NVS partition found in parts/ into a readable report.

Reports written and erased entries alike. An erased entry is still present on
flash until its page is compacted, so an old WiFi password or a superseded
token is routinely recoverable - and is often exactly what a challenge wants.
"""

import json
import os
import sys

import nvsfmt

WORK = os.environ.get("WORK", "/work")
PARTS = os.path.join(WORK, "parts")
REPORTS = os.path.join(WORK, "reports")
EXTRACT = os.path.join(WORK, "extract")


def render(path: str) -> tuple:
    data = open(path, "rb").read()
    if not nvsfmt.looks_like_nvs(data):
        return None, None

    pages, namespaces = nvsfmt.collect(data)
    lines = []
    records = []
    lines.append("NVS partition: %s (%d bytes, %d pages)"
                 % (os.path.basename(path), len(data), len(pages)))
    lines.append("namespaces: " + ", ".join(
        "%d=%s" % (k, v) for k, v in sorted(namespaces.items()) if k))
    lines.append("")

    written, erased = 0, 0
    for page in pages:
        if not page.entries:
            continue
        lines.append("-- page %d  state=%s  seq=%d  version=0x%02X"
                     % (page.index, page.state, page.seq_no, page.version))
        for e in page.entries:
            if e.state == "written":
                written += 1
            elif e.state == "erased":
                erased += 1

            value = e.value
            if isinstance(value, bytes):
                # Show short blobs inline; long ones go to a file.
                if len(value) <= 48:
                    shown = value.hex()
                    try:
                        text = value.decode("utf-8")
                        if text.isprintable():
                            shown = "%s  (%r)" % (value.hex(), text)
                    except UnicodeDecodeError:
                        pass
                else:
                    blobdir = os.path.join(EXTRACT, "nvs_blobs")
                    os.makedirs(blobdir, exist_ok=True)
                    safe = "".join(c if c.isalnum() or c in "._-" else "_"
                                   for c in "%s_%s" % (e.namespace, e.key))
                    blobpath = os.path.join(blobdir, safe + ".bin")
                    with open(blobpath, "wb") as fh:
                        fh.write(value)
                    shown = "<%d bytes -> extract/nvs_blobs/%s.bin>" % (len(value), safe)
                value = shown

            lines.append("   [%-7s] %-16s %-9s %-16s = %s"
                         % (e.state, e.namespace, e.type, e.key, value))
            records.append({
                "state": e.state, "namespace": e.namespace, "key": e.key,
                "type": e.type, "value": value if not isinstance(value, bytes) else value.hex(),
                "page": page.index,
            })
        lines.append("")

    lines.append("totals: %d written, %d erased-but-readable" % (written, erased))
    if erased:
        lines.append("NOTE: erased entries are stale values still on flash - check them.")
    return "\n".join(lines), records


def main():
    targets = sys.argv[1:]
    if not targets:
        if not os.path.isdir(PARTS):
            print("[x] No parts/ - run the split step first.", file=sys.stderr)
            return 1
        targets = sorted(os.path.join(PARTS, f) for f in os.listdir(PARTS) if f.endswith(".bin"))

    os.makedirs(REPORTS, exist_ok=True)
    found = 0
    all_records = {}
    for path in targets:
        report, records = render(path)
        if not report:
            continue
        found += 1
        label = os.path.splitext(os.path.basename(path))[0]
        dest = os.path.join(REPORTS, "nvs-%s.txt" % label)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(report + "\n")
        all_records[label] = records
        print(report)
        print("[+] wrote reports/nvs-%s.txt" % label)
        print()

    if not found:
        print("[!] No NVS partitions found in parts/.")
        return 0

    with open(os.path.join(WORK, "meta", "nvs.json"), "w", encoding="utf-8") as fh:
        json.dump(all_records, fh, indent=2)
    print("[+] wrote meta/nvs.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
