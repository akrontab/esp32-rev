#!/usr/bin/env python3
"""Extract filesystems out of carved partitions into extract/<label>/.

Handles SPIFFS and LittleFS natively and hands FAT to 7z. Anything a badge
stores as files - web assets, certificates, lookup tables, saved state - lands
here as ordinary files you can grep and open.
"""

import os
import shutil
import subprocess
import sys

import spiffsfmt

WORK = os.environ.get("WORK", "/work")
PARTS = os.path.join(WORK, "parts")
EXTRACT = os.path.join(WORK, "extract")


def safe_join(root: str, name: str) -> str:
    """Filenames come from the badge, so treat them as hostile: never let one
    escape the extraction directory."""
    cleaned = name.replace("\\", "/").lstrip("/")
    parts = [p for p in cleaned.split("/") if p not in ("", ".", "..")]
    if not parts:
        parts = ["unnamed"]
    return os.path.join(root, *parts)


def extract_spiffs(path: str, outdir: str) -> int:
    data = open(path, "rb").read()
    scan = spiffsfmt.scan(data)
    if not scan.files:
        return 0
    count = 0
    for f in scan.files:
        dest = safe_join(outdir, f.name)
        if f.deleted:
            dest = safe_join(os.path.join(outdir, "_deleted"), f.name)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(f.data)
        flag = " (deleted)" if f.deleted else ""
        warn = "  <- %s" % f.note if f.note else ""
        print("    %-40s %8d bytes%s%s" % (f.name, f.size, flag, warn))
        count += 1
    return count


def extract_littlefs(path: str, outdir: str) -> int:
    try:
        from littlefs import LittleFS
    except ImportError:
        print("    [!] littlefs-python is not available in this image")
        return 0

    data = open(path, "rb").read()
    # Block size is not recorded in a way we can rely on; try the sizes ESP-IDF
    # and the Arduino core actually ship with.
    for block_size in (4096, 8192, 512, 256):
        if len(data) % block_size:
            continue
        try:
            fs = LittleFS(block_size=block_size, block_count=len(data) // block_size, mount=False)
            fs.context.buffer = bytearray(data)
            fs.mount()
        except Exception:
            continue

        count = 0
        for root, _dirs, files in fs.walk("/"):
            for name in files:
                rel = (root.rstrip("/") + "/" + name).lstrip("/")
                try:
                    with fs.open("/" + rel, "rb") as src:
                        content = src.read()
                except Exception as e:
                    print("    [!] %s: %s" % (rel, e))
                    continue
                dest = safe_join(outdir, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as fh:
                    fh.write(content)
                print("    %-40s %8d bytes" % (rel, len(content)))
                count += 1
        print("    (mounted with block_size=%d)" % block_size)
        return count

    print("    [!] Could not mount as LittleFS at any common block size")
    return 0


def extract_fat(path: str, outdir: str) -> int:
    if not shutil.which("7z"):
        print("    [!] 7z not available")
        return 0
    os.makedirs(outdir, exist_ok=True)
    proc = subprocess.run(["7z", "x", "-y", "-o" + outdir, path],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        print("    [!] 7z could not read this as FAT")
        return 0
    return sum(len(files) for _r, _d, files in os.walk(outdir))


def detect(path: str) -> str:
    data = open(path, "rb").read(1 << 20)
    if b"littlefs" in data[:8192]:
        return "littlefs"
    if spiffsfmt.looks_like_spiffs(open(path, "rb").read()):
        return "spiffs"
    if data[510:512] == b"\x55\xaa" or b"FAT" in data[:64]:
        return "fat"
    return ""


def main():
    if not os.path.isdir(PARTS):
        print("[x] No parts/ directory - run the split step first.", file=sys.stderr)
        return 1

    targets = sys.argv[1:] or sorted(
        os.path.join(PARTS, f) for f in os.listdir(PARTS) if f.endswith(".bin"))

    total = 0
    for path in targets:
        label = os.path.splitext(os.path.basename(path))[0]
        kind = detect(path)
        if not kind:
            continue
        outdir = os.path.join(EXTRACT, label)
        os.makedirs(outdir, exist_ok=True)
        print("[*] %s: %s" % (label, kind))
        if kind == "spiffs":
            n = extract_spiffs(path, outdir)
        elif kind == "littlefs":
            n = extract_littlefs(path, outdir)
        else:
            n = extract_fat(path, outdir)
        if n:
            print("    -> %d files into extract/%s/" % (n, label))
            total += n
        else:
            os.rmdir(outdir) if not os.listdir(outdir) else None
            print("    -> nothing extracted")

    if total == 0:
        print("[!] No filesystems extracted. Either the badge has none, or the")
        print("    partition uses a non-default geometry - see docs/troubleshooting.md.")
    else:
        print()
        print("[+] %d files extracted into extract/" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
