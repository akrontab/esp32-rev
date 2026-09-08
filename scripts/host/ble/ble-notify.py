#!/usr/bin/env python3
"""Subscribe to a characteristic's notifications, or write then watch.

Some badge challenges do not hand you the answer on a plain read: they push
data via notifications (e.g. after you write a trigger value, or on a timer),
or they gate a value behind a write to another characteristic. This captures
that dynamic behaviour.

    ble-notify.py <addr> --notify <char-uuid> [--seconds 30]
    ble-notify.py <addr> --notify <char-uuid> --write <char-uuid>=<hex-or-str>
"""

import argparse
import asyncio
import datetime
import os
import sys

from bleak import BleakClient

WORK = os.environ.get("WORK", "/work")


def parse_value(spec: str) -> bytes:
    """Accept hex (0x.. or bare hex) or a plain string for the write payload."""
    if spec.startswith("0x"):
        return bytes.fromhex(spec[2:])
    try:
        return bytes.fromhex(spec)
    except ValueError:
        return spec.encode()


async def main():
    ap = argparse.ArgumentParser(description="Subscribe to BLE notifications")
    ap.add_argument("address")
    ap.add_argument("--notify", required=True, help="characteristic UUID to subscribe to")
    ap.add_argument("--write", help="CHAR=VALUE to write first (value as hex or string)")
    ap.add_argument("--seconds", type=float, default=30)
    args = ap.parse_args()

    logdir = os.path.join(WORK, "logs")
    os.makedirs(logdir, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    logpath = os.path.join(logdir, "ble-notify-%s.log" % stamp)
    log = open(logpath, "w")

    def handler(_char, data: bytearray):
        t = datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%S")
        printable = all(32 <= b < 127 or b in (9, 10, 13) for b in data)
        shown = data.decode("ascii", "replace") if printable else data.hex()
        line = "[%s] %s" % (t, shown)
        print("  " + line)
        log.write(line + "\n")
        log.flush()

    print("[*] Connecting to %s ..." % args.address)
    async with BleakClient(args.address) as client:
        if args.write:
            char, _, value = args.write.partition("=")
            payload = parse_value(value)
            print("[*] Writing %d bytes to %s" % (len(payload), char))
            await client.write_gatt_char(char, payload, response=True)

        print("[*] Subscribing to %s for %.0fs (Ctrl-C to stop)" % (args.notify, args.seconds))
        await client.start_notify(args.notify, handler)
        try:
            await asyncio.sleep(args.seconds)
        finally:
            await client.stop_notify(args.notify)

    log.close()
    print("[+] Notifications logged -> logs/%s" % os.path.basename(logpath))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except Exception as e:
        print("[x] %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(1)
