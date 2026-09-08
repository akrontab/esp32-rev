#!/usr/bin/env python3
"""Cross-target status: what has been acquired, what is still outstanding.

Reads the JSON the container tools leave behind, so it stays accurate without
re-running anything. Useful when a CTF has several badges, or when you come
back to a target after a day away.

    python scripts/host/summary.py workspace
"""

import json
import os
import sys

try:
    from rich.console import Console
    from rich.table import Table
    console = Console()
except ImportError:
    console = None


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def describe(target_dir: str) -> dict:
    meta = os.path.join(target_dir, "meta")
    info = read_json(os.path.join(meta, "target.json"), {}) or {}
    parts = read_json(os.path.join(meta, "partitions.json"), []) or []
    nvs = read_json(os.path.join(meta, "nvs.json"), {}) or {}

    dump = os.path.join(target_dir, "dumps", "flash_full.bin")
    dump_mb = "%.1f MB" % (os.path.getsize(dump) / 1e6) if os.path.isfile(dump) else "-"

    extract_dir = os.path.join(target_dir, "extract")
    extracted = 0
    if os.path.isdir(extract_dir):
        extracted = sum(len(f) for _r, _d, f in os.walk(extract_dir))

    # Count flag-shaped hits the hunt already found, so the summary answers
    # "did anything turn up here?" without opening a report.
    hunt = os.path.join(target_dir, "reports", "hunt.txt")
    leads = 0
    if os.path.isfile(hunt):
        with open(hunt, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        section = text.split("highest-value leads", 1)
        if len(section) > 1:
            leads = sum(1 for ln in section[1].splitlines()
                        if "{" in ln and not ln.startswith("---"))

    nvs_keys = sum(len(v) for v in nvs.values()) if isinstance(nvs, dict) else 0

    protection = []
    for key, label in (("flash_encryption_enabled", "flash-enc"),
                       ("secure_boot_enabled", "secure-boot"),
                       ("download_mode_disabled", "dl-disabled")):
        if info.get(key):
            protection.append(label)

    return {
        "chip": info.get("chip_model") or info.get("chip_family") or "-",
        "mac": info.get("mac", "-"),
        "flash": info.get("flash_size", "-"),
        "dump": dump_mb,
        "parts": len(parts),
        "files": extracted,
        "nvs": nvs_keys,
        "leads": leads,
        "protection": ",".join(protection) if protection else "-",
    }


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "workspace"
    if not os.path.isdir(root):
        print("No workspace directory at %s" % root, file=sys.stderr)
        return 1

    targets = sorted(d for d in os.listdir(root)
                     if os.path.isdir(os.path.join(root, d)) and not d.startswith("."))
    if not targets:
        print("No targets yet. Create one from the control plane (option 4).")
        return 0

    rows = [(t, describe(os.path.join(root, t))) for t in targets]

    if console:
        table = Table(title="Workspace summary")
        for col, just in (("target", "left"), ("chip", "left"), ("flash", "right"),
                          ("dump", "right"), ("parts", "right"), ("files", "right"),
                          ("nvs keys", "right"), ("leads", "right"), ("protection", "left")):
            table.add_column(col, justify=just)
        for name, d in rows:
            leads = "[bold green]%d[/bold green]" % d["leads"] if d["leads"] else "0"
            prot = "[yellow]%s[/yellow]" % d["protection"] if d["protection"] != "-" else "-"
            table.add_row(name, d["chip"], d["flash"], d["dump"], str(d["parts"]),
                          str(d["files"]), str(d["nvs"]), leads, prot)
        console.print(table)
    else:
        print("%-20s %-14s %-7s %-9s %5s %6s %5s %5s %s"
              % ("target", "chip", "flash", "dump", "parts", "files", "nvs", "lead", "protection"))
        for name, d in rows:
            print("%-20s %-14s %-7s %-9s %5d %6d %5d %5d %s"
                  % (name, d["chip"], d["flash"], d["dump"], d["parts"],
                     d["files"], d["nvs"], d["leads"], d["protection"]))

    print()
    for name, d in rows:
        if d["dump"] == "-":
            print("  %s: no dump yet - run acquisition (option 9)" % name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
