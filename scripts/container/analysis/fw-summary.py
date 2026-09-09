#!/usr/bin/env python3
"""Stitch every artefact a run produced into one reports/SUMMARY.md.

Reads the machine-readable outputs the other tools leave in meta/ and reports/
and composes a single human-readable brief: what the badge is, its security
posture, the partition layout, what was carved and extracted, NVS contents,
flag/secret leads, and BLE/WiFi findings when present. The detailed per-tool
files stay for drill-down; this is the one thing to read first.

Tolerant by design: every section degrades to a note if its input is missing,
so it works after a full run, an offline-only analysis, or a partial one.
"""

import json
import os
import re
import sys

WORK = os.environ.get("WORK", "/work")
META = os.path.join(WORK, "meta")
REPORTS = os.path.join(WORK, "reports")
EXTRACT = os.path.join(WORK, "extract")


def load_json(name, default=None):
    try:
        return json.load(open(os.path.join(META, name), encoding="utf-8"))
    except (OSError, ValueError):
        return default


def read_text(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def h(title):
    return "\n## %s\n" % title


def section_target(out):
    t = load_json("target.json", {}) or {}
    out.append(h("Target"))
    if not t:
        out.append("_No detection data (meta/target.json missing) — run acquisition._")
        return
    rows = [
        ("Chip", " ".join(x for x in [t.get("chip_model"), t.get("chip_revision")] if x)),
        ("Package", t.get("chip_package")),
        ("MAC", t.get("mac")),
        ("Flash", t.get("flash_size")),
        ("Crystal", t.get("crystal")),
        ("USB mode", t.get("usb_mode")),
        ("Features", t.get("features")),
    ]
    for k, v in rows:
        if v:
            out.append("- **%s:** %s" % (k, v))


def section_security(out):
    t = load_json("target.json", {}) or {}
    out.append(h("Security posture"))
    flags = [
        ("Flash encryption", t.get("flash_encryption_enabled")),
        ("Secure boot", t.get("secure_boot_enabled")),
        ("Download mode disabled", t.get("download_mode_disabled")),
        ("Secure download mode", t.get("secure_download_mode")),
    ]
    any_set = any(v for _, v in flags)
    for label, v in flags:
        mark = "**ENABLED**" if v else "off"
        out.append("- %s: %s" % (label, mark))
    if any_set:
        out.append("\n> Protection is on — a plain serial dump may be ciphertext or refused. "
                   "See docs/playbook.md (encrypted-flash branch).")
    else:
        out.append("\n> Nothing locked — plain dump and analysis are meaningful.")
    if os.path.isfile(os.path.join(REPORTS, "security-posture.txt")):
        out.append("\nDetail: `reports/security-posture.txt`")


def section_firmware(out):
    # Project / version / IDF come from the app descriptor, which triage prints.
    triage = read_text(os.path.join(REPORTS, "triage.txt"))
    m = re.search(r"project '([^']*)'\s+version '([^']*)'\s+idf (\S+)\s+built (.+)", triage)
    if m:
        out.append(h("Firmware identity"))
        out.append("- **Project:** %s" % m.group(1))
        out.append("- **Version:** %s" % m.group(2))
        out.append("- **ESP-IDF:** %s" % m.group(3))
        out.append("- **Built:** %s" % m.group(4).strip())
        out.append("\n> The exact IDF version lets you diff against a stock build to "
                   "separate badge code from SDK code (see docs/ghidra.md).")


def section_partitions(out):
    parts = load_json("partitions.json", []) or []
    manifest = {m["label"]: m for m in (load_json("parts_manifest.json", []) or [])}
    out.append(h("Partitions"))
    if not parts:
        out.append("_No partition table parsed._")
        return
    out.append("| label | type/subtype | offset | size | contents |")
    out.append("|---|---|---|---|---|")
    for p in parts:
        cls = manifest.get(p["label"], {}).get("classification", "")
        out.append("| %s | %s/%s | 0x%06x | %d KiB | %s |" % (
            p["label"], p["type"], p["subtype"], p["offset"], p["size"] // 1024, cls))


def section_extracted(out):
    if not os.path.isdir(EXTRACT):
        return
    files = []
    for root, _d, fs in os.walk(EXTRACT):
        for f in fs:
            rel = os.path.relpath(os.path.join(root, f), WORK)
            files.append(rel)
    if not files:
        return
    out.append(h("Files extracted (%d)" % len(files)))
    for rel in sorted(files)[:60]:
        out.append("- `%s`" % rel)
    if len(files) > 60:
        out.append("- ... and %d more (see extract/)" % (len(files) - 60))


def section_nvs(out):
    nvs = load_json("nvs.json", {}) or {}
    records = [r for recs in nvs.values() for r in recs] if isinstance(nvs, dict) else []
    if not records:
        return
    written = [r for r in records if r.get("state") == "written"]
    erased = [r for r in records if r.get("state") == "erased"]
    out.append(h("NVS (%d written, %d erased-but-readable)" % (len(written), len(erased))))
    for r in records:
        val = r.get("value", "")
        if isinstance(val, str) and len(val) > 60:
            val = val[:60] + "..."
        flag = "" if r.get("state") == "written" else " _(erased)_"
        out.append("- `%s` / `%s` (%s) = `%s`%s" % (
            r.get("namespace", ""), r.get("key", ""), r.get("type", ""), val, flag))
    if erased:
        out.append("\n> Erased entries are stale values still on flash — often the point on a CTF badge.")


def section_wifi(out):
    w = load_json("wifi.json", {})
    if not w:
        return
    caps = w.get("capabilities", {})
    cfg = w.get("config", [])
    if not caps and not cfg:
        return
    out.append(h("WiFi"))
    if caps:
        out.append("Capabilities: " + ", ".join(sorted(caps.keys())))
    for c in cfg:
        out.append("- config `%s` = `%s`" % (c.get("key"), c.get("value")))


def section_ble(out):
    tree = load_json("ble-gatt.json", [])
    if not tree:
        return
    nchar = sum(len(s.get("characteristics", [])) for s in tree)
    out.append(h("BLE GATT (%d services, %d characteristics)" % (len(tree), nchar)))
    for s in tree:
        for ch in s.get("characteristics", []):
            v = ch.get("value_hex")
            note = ""
            if v:
                try:
                    b = bytes.fromhex(v)
                    if all(32 <= x < 127 for x in b):
                        note = " = `%s`" % b.decode("ascii")
                except ValueError:
                    pass
            out.append("- `%s` [%s]%s" % (ch.get("uuid", "")[:8], ",".join(ch.get("properties", [])), note))


def section_leads(out):
    hunt = read_text(os.path.join(REPORTS, "hunt.txt"))
    out.append(h("Flag / secret leads"))
    if "highest-value leads" in hunt:
        tail = hunt.split("highest-value leads", 1)[1]
        lines = [l.strip() for l in tail.splitlines() if "{" in l and not l.startswith("-")]
        if lines:
            for l in lines[:20]:
                out.append("- `%s`" % l)
        else:
            out.append("_No flag-shaped strings found. Try MINLEN=4, custom patterns, "
                       "or disassembly ([33]). See reports/hunt.txt._")
    else:
        out.append("_Hunt not run yet ([17]/[12])._")


def main():
    os.makedirs(REPORTS, exist_ok=True)
    target = os.environ.get("TARGET", "unknown")

    out = ["# %s — run summary" % target,
           "",
           "_Generated by fw-summary. The one-page brief; detailed files are in reports/, "
           "meta/, parts/ and extract/._"]

    section_target(out)
    section_security(out)
    section_firmware(out)
    section_partitions(out)
    section_leads(out)
    section_nvs(out)
    section_extracted(out)
    section_wifi(out)
    section_ble(out)

    out.append("\n---\n")
    out.append("Artefact hashes: `meta/artifacts.sha256` (verify with control-plane [19]).")

    dest = os.path.join(REPORTS, "SUMMARY.md")
    with open(dest, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    print("[+] wrote reports/SUMMARY.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
