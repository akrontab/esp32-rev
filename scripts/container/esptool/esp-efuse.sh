#!/usr/bin/env bash
# Read the eFuse block and summarise the badge's security posture.
#
# This decides the whole approach: if flash encryption is on, a serial dump is
# ciphertext and static analysis of it is pointless; if secure boot is on, you
# cannot run modified firmware. Better to learn that in minute one.
#
# Read-only: espefuse is invoked without --do-not-confirm and we never pass a
# burn command, so nothing here can blow a fuse.

source /opt/re/lib/common.sh
init_workspace
require_port

RAW="$DIR_META/efuse_summary.txt"

log "Reading eFuse summary from $SERIAL_PORT"
espefuse_args=(--port "$SERIAL_PORT")
[ "$CHIP" != "auto" ] && espefuse_args+=(--chip "$CHIP")

if ! espefuse "${espefuse_args[@]}" summary 2>&1 | tee "$RAW"; then
  warn "espefuse summary returned an error; the captured output may still be useful."
fi

record "efuse" "port=$SERIAL_PORT"
register_artifact "$RAW"

hr
echo "### security posture"
hr
python3 - "$RAW" <<'PY'
import re, sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()

# eFuse names differ across targets, so match on the concept, not one spelling.
CHECKS = [
    ("Flash encryption",   r"FLASH_CRYPT_CNT.*?=\s*(\S+)|SPI_BOOT_CRYPT_CNT.*?=\s*(\S+)"),
    ("Secure boot v1",     r"ABS_DONE_0.*?=\s*(\S+)"),
    ("Secure boot v2",     r"(?:ABS_DONE_1|SECURE_BOOT_EN).*?=\s*(\S+)"),
    ("JTAG disabled",      r"(?:JTAG_DISABLE|DIS_PAD_JTAG|HARD_DIS_JTAG).*?=\s*(\S+)"),
    ("Download mode",      r"(?:DIS_DOWNLOAD_MODE|UART_DOWNLOAD_DIS).*?=\s*(\S+)"),
    ("Encrypt download",   r"DIS_DOWNLOAD_MANUAL_ENCRYPT.*?=\s*(\S+)"),
    ("Read protection",    r"RD_DIS.*?=\s*(\S+)"),
    ("Write protection",   r"WR_DIS.*?=\s*(\S+)"),
]

findings = []
for label, pat in CHECKS:
    m = re.search(pat, text)
    val = None
    if m:
        val = next((g for g in m.groups() if g), None)
    findings.append((label, val))

width = max(len(f[0]) for f in findings)
for label, val in findings:
    print("  %-*s %s" % (width + 1, label + ":", val if val else "not reported"))

lowered = text.lower()
blockers = []
if "flash encryption feature is enabled" in lowered:
    blockers.append("flash encryption is ENABLED - serial dumps will be ciphertext")
if "secure boot is enabled" in lowered or "secure boot enabled" in lowered:
    blockers.append("secure boot is ENABLED - the badge will not run modified firmware")

print()
if blockers:
    for b in blockers:
        print("  [!] " + b)
    print("  Read docs/playbook.md - the encrypted-flash branch applies to you.")
else:
    print("  [+] No hard blockers detected in the summary text.")
    print("      Still skim the raw output above; naming varies by chip revision.")
PY

hr
ok "eFuse summary saved to meta/efuse_summary.txt"
