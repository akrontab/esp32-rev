#!/usr/bin/env python3
"""Re-hash every recorded artefact in a target workspace.

Runs on the host inside .venv - it needs no container because it only reads
files. Point it at a workspace directory:

    python scripts/host/verify.py workspace/defcon-badge

A dump you are about to base hours of analysis on should be provably the same
dump you pulled off the badge. This is also how you catch a truncated or
half-written read after a cable knock.
"""

import hashlib
import os
import sys

try:
    from rich.console import Console
    from rich.table import Table
    console = Console()
except ImportError:                                    # venv not built yet
    console = None


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) < 2:
        print("usage: verify.py <workspace/target>", file=sys.stderr)
        return 2
    root = sys.argv[1]
    ledger = os.path.join(root, "meta", "artifacts.sha256")
    if not os.path.isfile(ledger):
        print("No meta/artifacts.sha256 in %s - nothing has been acquired yet." % root)
        return 1

    rows = []
    ok = changed = missing = 0
    with open(ledger, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            # Written by register_artifact as "<sha256>  <relative path>".
            recorded, _, rel = line.partition("  ")
            rel = rel.strip()
            if not rel:
                continue
            path = os.path.join(root, rel)
            if not os.path.isfile(path):
                rows.append((rel, "MISSING", "-", recorded[:16]))
                missing += 1
                continue
            actual = sha256_of(path)
            if actual == recorded:
                rows.append((rel, "ok", "%.1f MB" % (os.path.getsize(path) / 1e6), actual[:16]))
                ok += 1
            else:
                rows.append((rel, "CHANGED", "%.1f MB" % (os.path.getsize(path) / 1e6), actual[:16]))
                changed += 1

    if console:
        table = Table(title="Artefact verification - %s" % os.path.basename(root.rstrip("/\\")))
        table.add_column("artefact")
        table.add_column("status")
        table.add_column("size", justify="right")
        table.add_column("sha256")
        for rel, status, size, digest in rows:
            style = {"ok": "green", "CHANGED": "bold red", "MISSING": "yellow"}[status]
            table.add_row(rel, "[%s]%s[/%s]" % (style, status, style), size, digest)
        console.print(table)
    else:
        for rel, status, size, digest in rows:
            print("%-8s %-40s %10s %s" % (status, rel, size, digest))

    print()
    print("%d verified, %d changed, %d missing" % (ok, changed, missing))
    if changed:
        print("A changed artefact means the file no longer matches what was captured.")
    return 1 if (changed or missing) else 0


if __name__ == "__main__":
    sys.exit(main())
