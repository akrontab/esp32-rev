#!/usr/bin/env bash
# Headless FID-source builder for Ghidra name recovery.
#
# The slow, tedious part of building a FunctionID database is importing and
# ANALYSING the SDK's object files (a static lib is thousands of tiny .o's).
# This does that unattended, using Ghidra's own FID headless scripts
# (FunctionIDHeadlessPre/Postscript: FID/LID off, scalar-operand on, switch-fix),
# into a saved project in the workspace. Then in the GUI ([34]) you just open the
# project and run Function ID -> Populate FidDb (quick, since analysis is done),
# attach the .fidb to the badge, and run the Function ID analyzer.
#
#   gh-fid.sh <reference-subdir> [only-big]
#     reference-subdir : e.g. reference/arduino-esp32-2.0.16  (under /work, from [37])
#     only-big         : import just the big SDK libs a WiFi/BLE/crypto badge
#                        uses, instead of all of them (far faster)
#
# Output: <reference-subdir>/fidsrc/  (a Ghidra project) in the workspace.
set -euo pipefail

WORK="${WORK:-/work}"
REL="${1:?usage: gh-fid.sh <reference-subdir under /work> [only-big]}"
ONLY_BIG="${2:-}"
FID="$GHIDRA_HOME/Ghidra/Features/FunctionID/ghidra_scripts"

SRC="$WORK/$REL"
[ -d "$SRC" ] || { echo "[x] not found: $SRC  (run [37] first)"; exit 1; }
[ -f "$SRC/reference.elf" ] || { echo "[x] no reference.elf in $SRC"; exit 1; }
if [ ! -d "$SRC/lib" ]; then
    echo "[!] no lib/ in $SRC - rebuild the arduino image and re-run [37] to copy the SDK libs."
    echo "    Proceeding with reference.elf only (limited coverage)."
fi

PROJDIR="$SRC/fidsrc"
rm -rf "$PROJDIR"
mkdir -p "$PROJDIR"

# What to feed the importer. reference.elf always; then the libs.
IMPORTS=("$SRC/reference.elf")
if [ -d "$SRC/lib" ]; then
    if [ "$ONLY_BIG" = "only-big" ]; then
        for n in libcore libnet80211 libbt libbtdm_app libmbedtls libmbedcrypto \
                 libwpa_supplicant libesp_wifi libesp_system libnvs_flash liblwip \
                 libesp_event libesp_netif libnghttp libesp-tls libcoap; do
            for f in "$SRC/lib/${n}"*.a; do [ -f "$f" ] && IMPORTS+=("$f"); done
        done
    else
        IMPORTS+=("$SRC/lib")
    fi
fi

echo "[*] Importing + analysing into ${REL}/fidsrc/  (the slow part - unattended)."
[ "$ONLY_BIG" = "only-big" ] && echo "    (only-big: the core SDK libs, not all 98)"
LOG="$PROJDIR/import.log"
analyzeHeadless "$PROJDIR" fidsrc \
    -import "${IMPORTS[@]}" -recursive \
    -scriptPath "$FID" \
    -preScript FunctionIDHeadlessPrescript.java \
    -postScript FunctionIDHeadlessPostscript.java 2>&1 | tee "$LOG" \
    | grep -viE "^(INFO|WARN|Using|Picked|OpenJDK|openjdk|jar:file)| /opt/ghidra" | tail -20 || true

SAVED="$(grep -c 'REPORT: Save succeeded' "$LOG" 2>/dev/null || echo 0)"
NOFUNC="$(grep -c 'has no functions' "$LOG" 2>/dev/null || echo 0)"
rm -f "$LOG"

echo
echo "[+] FID source project ready: ${REL}/fidsrc/   (${SAVED} programs analysed, ${NOFUNC} empty)"
echo "    Next, in the GUI ([34]):"
echo "      1. File -> Open Project -> /work/${REL}/fidsrc/fidsrc.gpr"
echo "      2. Function ID -> Create new empty FidDb"
echo "      3. Function ID -> Populate FidDb from Programs"
echo "         (Root Folder = /, Language = Xtensa:LE:32:default) - quick; analysis is done."
echo "      4. Open the badge -> Choose active FidDbs -> Analysis -> One Shot -> Function ID."
echo "    See docs/name-recovery.md."
