#!/usr/bin/env python3
"""Capture the badge's serial console, with an optional reset first.

The boot log is one of the richest free sources of information on an unknown
badge: the ROM header line gives the boot mode and strapping, the second-stage
bootloader prints the partition it chose, and the app usually prints its own
banner, version and log tags. Capturing it is often faster than reversing for
the same facts.

Every line is timestamped and written to logs/ as well as the terminal, so the
capture is citable evidence rather than scrollback.
"""

import argparse
import datetime
import os
import sys
import time

import serial

WORK = os.environ.get("WORK", "/work")


def hard_reset(ser, into_bootloader=False):
    """Toggle EN via the DTR/RTS auto-reset circuit found on ESP dev boards.

    IO0 (DTR) held low during release enters the serial bootloader; held high
    it boots the application normally.
    """
    ser.setDTR(into_bootloader)   # IO0
    ser.setRTS(True)              # EN low -> in reset
    time.sleep(0.12)
    ser.setRTS(False)             # EN high -> released
    time.sleep(0.05)
    ser.setDTR(False)


def main():
    ap = argparse.ArgumentParser(description="Timestamped serial console capture")
    ap.add_argument("--port", default=os.environ.get("SERIAL_PORT"))
    # The app console baud is not the flash-programming baud; 115200 is the
    # ESP-IDF default and what almost every badge will be using.
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=60,
                    help="stop after N seconds; 0 means run until Ctrl-C")
    ap.add_argument("--reset", action="store_true", help="reset the badge first to catch the boot log")
    ap.add_argument("--bootloader", action="store_true", help="reset into the serial bootloader instead")
    ap.add_argument("--raw", action="store_true", help="do not prefix timestamps")
    args = ap.parse_args()

    if not args.port:
        print("[x] No serial port. Attach the badge first.", file=sys.stderr)
        return 2

    logdir = os.path.join(WORK, "logs")
    os.makedirs(logdir, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    logpath = os.path.join(logdir, "serial-%s.log" % stamp)

    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.2)
    except serial.SerialException as e:
        print("[x] Cannot open %s: %s" % (args.port, e), file=sys.stderr)
        return 1

    print("[*] Monitoring %s at %d baud -> logs/%s" % (args.port, args.baud, os.path.basename(logpath)))
    if args.seconds:
        print("[*] Stopping after %.0fs (Ctrl-C to stop sooner)" % args.seconds)
    else:
        print("[*] Ctrl-C to stop")

    if args.reset or args.bootloader:
        print("[*] Resetting the badge%s" % (" into the bootloader" if args.bootloader else ""))
        ser.reset_input_buffer()
        hard_reset(ser, into_bootloader=args.bootloader)

    start = time.time()
    buf = b""
    written = 0
    try:
        with open(logpath, "w", encoding="utf-8", errors="replace") as log:
            while True:
                if args.seconds and (time.time() - start) > args.seconds:
                    break
                chunk = ser.read(4096)
                if not chunk:
                    continue
                buf += chunk
                # Emit whole lines only, so timestamps line up with log records.
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    text = line.rstrip(b"\r").decode("utf-8", "replace")
                    if args.raw:
                        out = text
                    else:
                        out = "[%7.3f] %s" % (time.time() - start, text)
                    print(out, flush=True)
                    log.write(out + "\n")
                    written += 1
                log.flush()
    except KeyboardInterrupt:
        print("\n[*] Stopped by user")
    finally:
        if buf:
            tail = buf.decode("utf-8", "replace")
            print(tail)
        ser.close()

    print("[+] %d lines captured -> logs/%s" % (written, os.path.basename(logpath)))
    if written == 0:
        print("[!] Nothing received. Try a different baud (74880 is the ESP ROM default on some")
        print("    parts), check TX/RX wiring, or the badge may hold the console off.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
