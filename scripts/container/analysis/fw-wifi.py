#!/usr/bin/env python3
"""Report the badge's WiFi capabilities and stored config, offline from the dump.

Two sources:
  1. NVS - ESP-IDF stores WiFi config in the namespace "nvs.net80211":
     opmode (STA/AP/APSTA), sta.ssid / sta.pswd, ap.ssid / ap.passwd, etc.
     A provisioned badge often has real credentials sitting here in the clear.
  2. The app image strings - which WiFi features the firmware actually uses
     (SoftAP, station, ESP-NOW, mesh, SmartConfig, WPS, promiscuous/monitor,
     an HTTP server or captive portal).

This answers "what can this badge do over WiFi, and what has it been told to
connect to" without ever powering the radio.
"""

import json
import os
import re
import sys

import espfmt
import nvsfmt

WORK = os.environ.get("WORK", "/work")
PARTS = os.path.join(WORK, "parts")

# opmode values from esp_wifi_types.h.
OPMODE = {0: "NULL (off)", 1: "STA (station)", 2: "AP (SoftAP)", 3: "APSTA (both)"}

# Capability markers -> human meaning. Grouped so the report reads as a
# feature inventory rather than a grep dump.
CAPABILITY_MARKERS = {
    "SoftAP (hosts its own network)": [r"esp_wifi_set_config.*AP", r"\bsoftap\b", r"wifi_ap_config", r"ap\.ssid"],
    "Station (joins a network)":      [r"esp_wifi_connect", r"wifi_sta_config", r"sta\.ssid"],
    "ESP-NOW (peer-to-peer)":         [r"esp_now_", r"espnow"],
    "WiFi mesh":                      [r"esp_mesh_", r"\bmesh\b"],
    "SmartConfig provisioning":       [r"smartconfig", r"esp_smartconfig"],
    "WPS":                            [r"esp_wifi_wps", r"\bwps_\b"],
    "Promiscuous / monitor mode":     [r"promiscuous", r"esp_wifi_set_promiscuous"],
    "Scanning":                       [r"esp_wifi_scan_start", r"scan_done"],
    "HTTP server":                    [r"httpd_", r"esp_http_server", r"/generate_204", r"captive"],
}


def find_nvs_partitions():
    out = []
    if not os.path.isdir(PARTS):
        return out
    for f in sorted(os.listdir(PARTS)):
        if not f.endswith(".bin"):
            continue
        path = os.path.join(PARTS, f)
        try:
            data = open(path, "rb").read()
        except OSError:
            continue
        if nvsfmt.looks_like_nvs(data):
            out.append((f, data))
    return out


def printable_strings(raw, minlen=3):
    return re.findall(rb"[\x20-\x7e]{%d,}" % minlen, raw)


def wifi_config_from_nvs():
    """Pull WiFi config out of any net80211 NVS namespace."""
    findings = []
    for fname, data in find_nvs_partitions():
        pages, namespaces = nvsfmt.collect(data)
        for page in pages:
            for e in page.entries:
                ns = e.namespace or ""
                key = e.key or ""
                # net80211 namespace, or the well-known key names, wherever they land.
                is_wifi = ("net80211" in ns.lower() or
                           re.match(r"^(sta|ap)\.", key) or key == "opmode")
                if not is_wifi:
                    continue
                rec = {"partition": fname, "namespace": ns, "key": key,
                       "type": e.type, "state": e.state}
                if key == "opmode" and isinstance(e.value, int):
                    rec["value"] = OPMODE.get(e.value, "0x%02X" % e.value)
                elif isinstance(e.value, bytes):
                    # SSID/password live as ASCII inside the blob; surface them.
                    strs = [s.decode("ascii", "replace") for s in printable_strings(e.value, 1)]
                    rec["value"] = " ".join(strs) if strs else e.value.hex()
                else:
                    rec["value"] = e.value
                findings.append(rec)
    return findings


def capabilities_from_strings():
    strings_file = os.path.join(WORK, "reports", "strings.txt")
    text = ""
    if os.path.isfile(strings_file):
        text = open(strings_file, encoding="utf-8", errors="replace").read()
    else:
        # No pre-extracted strings; scan the app partitions directly.
        for fname, data in [(f, open(os.path.join(PARTS, f), "rb").read())
                            for f in os.listdir(PARTS) if f.endswith(".bin")] if os.path.isdir(PARTS) else []:
            text += "\n".join(s.decode("ascii", "replace") for s in printable_strings(data))

    present = {}
    for cap, pats in CAPABILITY_MARKERS.items():
        hits = 0
        for p in pats:
            hits += len(re.findall(p, text, re.I))
        if hits:
            present[cap] = hits

    # Hardcoded SSID-ish lines near wifi context (heuristic, for review).
    ssid_like = sorted(set(re.findall(r'ssid["\'`:= ]{1,4}([A-Za-z0-9_\-]{2,32})', text, re.I)))
    return present, ssid_like[:20]


def main():
    if not os.path.isdir(PARTS):
        print("[x] No parts/ - run the analysis pipeline (split) first.", file=sys.stderr)
        return 1

    cfg = wifi_config_from_nvs()
    caps, ssids = capabilities_from_strings()

    lines = ["WiFi capability report", "=" * 40, ""]

    lines.append("## Stored WiFi config (from NVS)")
    if cfg:
        for r in cfg:
            flag = "" if r["state"] == "written" else "  [%s]" % r["state"]
            lines.append("  %-14s %-10s = %s%s" % (r["key"], "(%s)" % r["type"], r["value"], flag))
        lines.append("  NOTE: erased entries are stale but still readable - old creds live here.")
    else:
        lines.append("  none found (badge may not store WiFi creds, or uses no station mode)")
    lines.append("")

    lines.append("## WiFi features used by the firmware")
    if caps:
        for cap, n in sorted(caps.items(), key=lambda kv: -kv[1]):
            lines.append("  [x] %-34s (%d references)" % (cap, n))
    else:
        lines.append("  no obvious WiFi feature markers - firmware may not use WiFi")
    lines.append("")

    if ssids:
        lines.append("## SSID-shaped strings (review by hand)")
        for s in ssids:
            lines.append("  %s" % s)
        lines.append("")

    report = "\n".join(lines)
    print(report)

    os.makedirs(os.path.join(WORK, "reports"), exist_ok=True)
    os.makedirs(os.path.join(WORK, "meta"), exist_ok=True)
    with open(os.path.join(WORK, "reports", "wifi.txt"), "w", encoding="utf-8") as fh:
        fh.write(report + "\n")
    with open(os.path.join(WORK, "meta", "wifi.json"), "w", encoding="utf-8") as fh:
        json.dump({"config": cfg, "capabilities": caps, "ssid_candidates": ssids}, fh, indent=2)

    print("[+] wrote reports/wifi.txt and meta/wifi.json")
    if any("AP" in str(r.get("value", "")) or r["key"].startswith("ap.") for r in cfg) or \
       "SoftAP (hosts its own network)" in caps:
        print("[*] Badge appears to host a SoftAP - scan for it live with the host WiFi scan.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
