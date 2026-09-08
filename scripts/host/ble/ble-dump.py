#!/usr/bin/env python3
"""Connect to a BLE peripheral, enumerate its GATT table, and read everything.

This is the workhorse. GATT (Generic Attribute Profile) is how a BLE device
exposes data: a tree of services, each holding characteristics, each holding a
value you can read, write or subscribe to. On a challenge badge the puzzle
content lives in characteristic values - so reading them all, once, is very
often the entire "attack".

On the 2025 badge, doing exactly this would have surfaced the cipher strings,
the hash to crack, and the challenge banners in one pass.

Every readable characteristic is dumped to extract/ble/ and summarised in
reports/ble-gatt.txt, with printable values shown inline and decode hints for
the common CTF encodings (hex/base64/base32/rot13).
"""

import argparse
import asyncio
import base64
import codecs
import json
import os
import sys

from bleak import BleakClient

WORK = os.environ.get("WORK", "/work")


def decode_hints(raw: bytes) -> list:
    """Suggest what an opaque value might decode to - the badge's ciphers were
    exactly these transforms, so surfacing them saves a manual round-trip."""
    hints = []
    text = None
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        return hints
    stripped = text.strip()

    if stripped and all(c.isalpha() or c.isspace() for c in stripped):
        try:
            hints.append(("rot13", codecs.decode(stripped, "rot_13")))
        except Exception:
            pass
    for name, fn in (("base64", base64.b64decode), ("base32", base64.b32decode)):
        try:
            dec = fn(stripped + "=" * (-len(stripped) % 8))
            if dec and all(32 <= b < 127 for b in dec):
                hints.append((name, dec.decode("ascii")))
        except Exception:
            pass
    return hints


async def main():
    ap = argparse.ArgumentParser(description="Enumerate and read a BLE device's GATT")
    ap.add_argument("address", help="BD address of the target (from ble-scan)")
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("--no-read", action="store_true", help="map the tree but do not read values")
    args = ap.parse_args()

    outdir = os.path.join(WORK, "extract", "ble")
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(os.path.join(WORK, "reports"), exist_ok=True)

    lines = []
    tree = []

    def emit(s=""):
        print(s)
        lines.append(s)

    emit("[*] Connecting to %s ..." % args.address)
    async with BleakClient(args.address, timeout=args.timeout) as client:
        emit("[+] Connected. Enumerating GATT services.\n")
        for service in client.services:
            emit("service %s  %s" % (service.uuid, service.description))
            svc = {"uuid": service.uuid, "description": service.description, "characteristics": []}
            for ch in service.characteristics:
                props = ",".join(ch.properties)
                entry = {"uuid": ch.uuid, "handle": ch.handle,
                         "description": ch.description, "properties": ch.properties}
                emit("  char %s  handle=0x%04x  [%s]  %s"
                     % (ch.uuid, ch.handle, props, ch.description))

                if not args.no_read and "read" in ch.properties:
                    try:
                        val = await client.read_gatt_char(ch)
                    except Exception as e:
                        emit("      (read failed: %s)" % e)
                        val = None
                    if val is not None:
                        entry["value_hex"] = val.hex()
                        # Save raw bytes; name by handle so nothing collides.
                        safe = "%04x_%s" % (ch.handle, ch.uuid.split("-")[0])
                        with open(os.path.join(outdir, "char_%s.bin" % safe), "wb") as fh:
                            fh.write(val)
                        printable = all(32 <= b < 127 or b in (9, 10, 13) for b in val) and len(val) > 0
                        if printable:
                            emit("      value: %r" % val.decode("ascii", "replace"))
                        else:
                            emit("      value: %s" % (val.hex() if val else "(empty)"))
                        for name, dec in decode_hints(val):
                            emit("      hint[%s]: %s" % (name, dec))
                svc["characteristics"].append(entry)
            tree.append(svc)
            emit("")

    with open(os.path.join(WORK, "reports", "ble-gatt.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(WORK, "meta", "ble-gatt.json"), "w") as fh:
        json.dump(tree, fh, indent=2)

    emit("[+] GATT map -> reports/ble-gatt.txt, raw values -> extract/ble/")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except Exception as e:
        print("[x] %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(1)
