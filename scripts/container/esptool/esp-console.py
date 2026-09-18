#!/usr/bin/env python3
"""Interactive two-way serial terminal for the badge.

esp-monitor.py only *reads* the console. This is the interactive counterpart:
whatever the badge prints is shown (and logged), and whatever you type is sent
straight to it - so you can drive a CLI, walk a single-keypress menu, or answer
a prompt the firmware puts up. Many badge challenges are exactly that: a menu
or a command you have to find and feed the right input.

Runs char-at-a-time in raw mode so single-key menus and REPLs work, and control
keys (Ctrl-C, Ctrl-Z, ...) are forwarded to the badge rather than caught by the
host - so you can interrupt a command running on the device. The whole session
is timestamped into logs/ as evidence.

Exit with Ctrl-] (does not reset the badge). Runs inside the esptool container,
which docker gives a real pty (-it), so raw-mode stdin works.
"""

import argparse
import datetime
import os
import sys
import threading
import time

import serial

WORK = os.environ.get("WORK", "/work")

EXIT_KEY = 0x1D            # Ctrl-]  (like telnet/miniterm)
EOL = {"cr": b"\r", "lf": b"\n", "crlf": b"\r\n"}


def hard_reset(ser, into_bootloader=False):
    """Toggle EN via the DTR/RTS auto-reset circuit (same as esp-monitor)."""
    ser.setDTR(into_bootloader)   # IO0
    ser.setRTS(True)              # EN low -> in reset
    time.sleep(0.12)
    ser.setRTS(False)             # EN high -> released
    time.sleep(0.05)
    ser.setDTR(False)


def reader_loop(ser, log, stop):
    """Serial -> stdout (raw, so colour/control codes pass through) + logfile."""
    out = sys.stdout.buffer
    while not stop.is_set():
        try:
            data = ser.read(4096)
        except serial.SerialException as e:
            sys.stderr.write("\r\n[x] serial read error: %s\r\n" % e)
            stop.set()
            break
        if not data:
            continue
        out.write(data)
        out.flush()
        log.write(data.decode("utf-8", "replace"))
        log.flush()


def interactive(ser, eol, local_echo):
    """stdin -> serial, char at a time, until the exit key."""
    import termios
    import tty
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    # Raw (not cbreak): control chars go to the badge, not the host tty, so the
    # only key we intercept is the exit key. Ctrl-C etc. reach the firmware.
    tty.setraw(fd)
    try:
        while True:
            ch = os.read(fd, 1)
            if not ch:
                break
            b = ch[0]
            if b == EXIT_KEY:
                break
            if b in (0x0D, 0x0A):        # Enter -> the configured line ending
                ser.write(eol)
                if local_echo:
                    sys.stdout.write("\r\n")
                    sys.stdout.flush()
            else:
                ser.write(ch)
                if local_echo:
                    sys.stdout.buffer.write(ch)
                    sys.stdout.buffer.flush()
            ser.flush()
            # Keystrokes are not logged verbatim (they can carry secrets, and the
            # badge's own echo already lands in the received log).
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def line_mode(ser, eol):
    """Fallback when stdin is not a tty: read whole lines and send them."""
    print("[*] stdin is not a terminal - line mode (type a command, Enter to send; Ctrl-D to quit)")
    for line in sys.stdin:
        ser.write(line.rstrip("\r\n").encode("utf-8", "replace") + eol)
        ser.flush()


def main():
    ap = argparse.ArgumentParser(description="Interactive two-way serial terminal")
    ap.add_argument("--port", default=os.environ.get("SERIAL_PORT"))
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--eol", choices=list(EOL), default="lf",
                    help="what Enter sends (default lf; try cr or crlf if the badge ignores commands)")
    ap.add_argument("--echo", action="store_true",
                    help="locally echo typed characters (use if the badge does not echo)")
    ap.add_argument("--reset", action="store_true", help="reset the badge first to catch the boot log")
    ap.add_argument("--bootloader", action="store_true", help="reset into the serial bootloader instead")
    args = ap.parse_args()

    if not args.port:
        print("[x] No serial port. Attach the badge first.", file=sys.stderr)
        return 2

    logdir = os.path.join(WORK, "logs")
    os.makedirs(logdir, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    logpath = os.path.join(logdir, "console-%s.log" % stamp)

    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.2)
    except serial.SerialException as e:
        print("[x] Cannot open %s: %s" % (args.port, e), file=sys.stderr)
        return 1

    eol = EOL[args.eol]
    print("[*] Interactive console on %s at %d baud -> logs/%s"
          % (args.port, args.baud, os.path.basename(logpath)))
    print("[*] Enter sends %r  |  Ctrl-] to quit%s"
          % (eol, "  |  local echo on" if args.echo else ""))

    stop = threading.Event()
    with open(logpath, "w", encoding="utf-8", errors="replace") as log:
        log.write("# esp-console %s  port=%s baud=%d eol=%s\n"
                  % (stamp, args.port, args.baud, args.eol))
        log.flush()

        if args.reset or args.bootloader:
            print("[*] Resetting the badge%s" % (" into the bootloader" if args.bootloader else ""))
            ser.reset_input_buffer()
            hard_reset(ser, into_bootloader=args.bootloader)

        rt = threading.Thread(target=reader_loop, args=(ser, log, stop), daemon=True)
        rt.start()
        try:
            if sys.stdin.isatty():
                interactive(ser, eol, args.echo)
            else:
                line_mode(ser, eol)
        except KeyboardInterrupt:
            pass
        finally:
            stop.set()
            rt.join(timeout=1.0)
            ser.close()

    print("\n[+] Console closed -> logs/%s" % os.path.basename(logpath))
    return 0


if __name__ == "__main__":
    sys.exit(main())
