#!/usr/bin/env python3
"""Scan for BLE peripherals and save what is advertising.

The badge advertises itself before you ever connect - its name, service UUIDs
and any manufacturer data are all visible passively. This is the BLE
equivalent of chip identification: do it first, and it often names the
challenge services outright.

Results are printed and written to reports/ble-scan.txt / .json.
"""

import argparse
import asyncio
import json
import os
import sys

from bleak import BleakScanner

WORK = os.environ.get("WORK", "/work")


async def main():
    ap = argparse.ArgumentParser(description="Scan for BLE devices")
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--name", help="only show devices whose name contains this (case-insensitive)")
    args = ap.parse_args()

    print("[*] Scanning for %.0fs ..." % args.seconds)
    # return_adv gives us the advertisement data, not just address+name.
    found = await BleakScanner.discover(timeout=args.seconds, return_adv=True)

    rows = []
    for addr, (dev, adv) in found.items():
        name = adv.local_name or dev.name or ""
        if args.name and args.name.lower() not in name.lower():
            continue
        rows.append({
            "address": addr,
            "name": name,
            "rssi": adv.rssi,
            "service_uuids": list(adv.service_uuids or []),
            "manufacturer_data": {str(k): v.hex() for k, v in (adv.manufacturer_data or {}).items()},
            "service_data": {k: v.hex() for k, v in (adv.service_data or {}).items()},
        })

    rows.sort(key=lambda r: r["rssi"], reverse=True)      # strongest first = closest

    if not rows:
        print("[!] No devices found.")
        print("    If you expected the badge: check it is powered and advertising,")
        print("    and that a working BLE adapter is attached (see docs/ble.md).")
    for r in rows:
        print("\n  %s  rssi=%sdBm  %s" % (r["address"], r["rssi"], r["name"] or "(no name)"))
        for u in r["service_uuids"]:
            print("      service: %s" % u)
        for k, v in r["manufacturer_data"].items():
            print("      mfr[%s]: %s" % (k, v))

    os.makedirs(os.path.join(WORK, "reports"), exist_ok=True)
    with open(os.path.join(WORK, "reports", "ble-scan.json"), "w") as fh:
        json.dump(rows, fh, indent=2)
    with open(os.path.join(WORK, "reports", "ble-scan.txt"), "w") as fh:
        for r in rows:
            fh.write("%s  rssi=%s  %s\n" % (r["address"], r["rssi"], r["name"]))
            for u in r["service_uuids"]:
                fh.write("    service: %s\n" % u)

    print("\n[+] %d device(s) -> reports/ble-scan.json" % len(rows))
    print("[*] Next: enumerate the badge's GATT table with its address.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except Exception as e:
        print("[x] %s: %s" % (type(e).__name__, e), file=sys.stderr)
        print("    A BlueZ/D-Bus error here almost always means no working adapter.", file=sys.stderr)
        sys.exit(1)
