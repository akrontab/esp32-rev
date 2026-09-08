#!/usr/bin/env python3
"""Scan for nearby WiFi networks from the Windows host, to find a badge SoftAP.

Like BLE, WiFi cannot be driven from a Docker Desktop container (no adapter
passthrough / wireless stack), so this runs host-side and uses the Windows
WLAN API via `netsh`. It is passive reconnaissance: it lists what is
advertising, so you can spot a badge that hosts its own access point.

Deauth, handshake capture and monitor mode are NOT here - those need a
dedicated adapter and a real Linux host (see docs/roadmap.md). This is
capability/recon only.
"""

import json
import os
import re
import subprocess
import sys

WORK = os.environ.get("WORK", os.getcwd())

# SSID substrings that hint "this is a badge / CTF AP", highlighted in output.
BADGE_HINTS = ("badge", "ctf", "esp", "esp32", "hack", "wwhf", "bhis", "dc", "defcon", "flag")


def run_netsh(args):
    try:
        out = subprocess.run(["netsh", "wlan"] + args, capture_output=True,
                             text=True, timeout=30)
        return out.stdout
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        print("[x] netsh failed: %s" % e, file=sys.stderr)
        return ""


def parse_networks(text):
    """Parse `netsh wlan show networks mode=bssid` output into structured rows."""
    nets = []
    cur = None
    bss = None
    for line in text.splitlines():
        m = re.match(r"^SSID \d+ : (.*)$", line.strip())
        if m:
            cur = {"ssid": m.group(1).strip(), "auth": "", "encryption": "",
                   "bssids": []}
            nets.append(cur)
            bss = None
            continue
        if cur is None:
            continue
        s = line.strip()
        if s.startswith("Authentication"):
            cur["auth"] = s.split(":", 1)[1].strip()
        elif s.startswith("Encryption"):
            cur["encryption"] = s.split(":", 1)[1].strip()
        elif re.match(r"^BSSID \d+", s):
            bss = {"bssid": s.split(":", 1)[1].strip(), "signal": "", "radio": "", "channel": ""}
            cur["bssids"].append(bss)
        elif bss is not None and s.startswith("Signal"):
            bss["signal"] = s.split(":", 1)[1].strip()
        elif bss is not None and s.startswith("Radio type"):
            bss["radio"] = s.split(":", 1)[1].strip()
        elif bss is not None and s.startswith("Channel"):
            # 802.11ax rows append band-utilisation in parens; keep just the number.
            bss["channel"] = s.split(":", 1)[1].strip().split()[0]
    return nets


def looks_like_badge(ssid):
    low = ssid.lower()
    return any(h in low for h in BADGE_HINTS)


def main():
    print("[*] Scanning WiFi via the Windows WLAN service ...")
    text = run_netsh(["show", "networks", "mode=bssid"])
    if not text:
        print("[!] No output. Is WiFi enabled and a wireless adapter present?")
        return 1

    nets = parse_networks(text)
    # Open / hidden / badge-hint networks first - those are the interesting ones.
    def rank(n):
        return (looks_like_badge(n["ssid"]),
                "Open" in n["auth"] or n["auth"] == "",
                n["ssid"] == "")
    nets.sort(key=rank, reverse=True)

    for n in nets:
        tag = "  <-- possible badge" if looks_like_badge(n["ssid"]) else ""
        name = n["ssid"] or "(hidden)"
        sig = n["bssids"][0]["signal"] if n["bssids"] else "?"
        ch = n["bssids"][0]["channel"] if n["bssids"] else "?"
        print("  %-32s %-16s sig=%-5s ch=%-4s%s" % (name, n["auth"], sig, ch, tag))

    os.makedirs(os.path.join(WORK, "reports"), exist_ok=True)
    with open(os.path.join(WORK, "reports", "wifi-scan.json"), "w") as fh:
        json.dump(nets, fh, indent=2)
    with open(os.path.join(WORK, "reports", "wifi-scan.txt"), "w") as fh:
        for n in nets:
            fh.write("%s\t%s\t%s\n" % (n["ssid"] or "(hidden)", n["auth"],
                                       n["bssids"][0]["signal"] if n["bssids"] else ""))

    hits = [n["ssid"] for n in nets if looks_like_badge(n["ssid"])]
    print()
    print("[+] %d network(s) -> reports/wifi-scan.json" % len(nets))
    if hits:
        print("[*] Possible badge AP(s): %s" % ", ".join(hits))
        print("    If open, connect from Windows and probe its services (HTTP, etc.).")
    else:
        print("[*] Nothing obviously badge-like. If the badge should host an AP,")
        print("    power-cycle it and rescan - SoftAP may start only in a certain mode.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
