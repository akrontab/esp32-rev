#!/usr/bin/env bash
# Headless Ghidra analysis of an ESP32 app image, end to end:
#   1. gh-prep: split the image into segments + a memory map
#   2. import the entry-bearing segment at its real address with the right
#      language (Xtensa or RISC-V), map the rest as blocks (AddSegments)
#   3. auto-analyse, then export decompilation/symbols/strings (ExportArtifacts)
#
# Everything lands in reports/ghidra/. Offline; reads only the workspace.

set -euo pipefail
WORK="${WORK:-/work}"
# GHIDRA_OUT lets gh-dump.sh point one image's artefacts at its own subdir;
# unset, it's the shared reports/ghidra (the [33] default). gh-prep.py reads
# the same variable, so the segment files and the manifest stay together.
OUT="${GHIDRA_OUT:-$WORK/reports/ghidra}"
SCRIPTS=/opt/re/bin
IMG="${1:-$WORK/parts/app0.bin}"

echo "[*] Preparing segments from $(basename "$IMG")"
gh-prep.py "$IMG"

# Pull language / entry / primary segment out of the manifest.
read -r LANG ENTRY PRIMARY_FILE PRIMARY_BASE < <(python3 - "$OUT/segments.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
p = m["segments"][m["primary"]]
print(m["language"], hex(m["entry"]), p["file"], hex(p["base"]))
PY
)

echo "[*] language=$LANG  entry=$ENTRY  primary=$PRIMARY_FILE @ $PRIMARY_BASE"

mkdir -p "$OUT"
PROJ_NAME="badge"

# analyzeHeadless: import the primary segment as raw binary at its base with the
# chosen processor; AddSegments (preScript) maps the others; analysis runs;
# ExportArtifacts (postScript) writes the reports. By default -deleteProject
# keeps the workspace clean (we keep the exported files, not the .gpr).
#
# With --keep, persist the analyzed project INTO the workspace (reports/ghidra/
# project/) instead of a throwaway temp dir, so [34] can open it directly -
# fully mapped, analysed and named - with no manual segment import. Cleared
# first so a re-run starts fresh (no stale lock / import-name clash).
KEEP="-deleteProject"
if [ "${2:-}" = "--keep" ]; then
    KEEP=""
    PROJ_DIR="$OUT/project"
    rm -rf "$PROJ_DIR"
    mkdir -p "$PROJ_DIR"
else
    PROJ_DIR="$(mktemp -d)"
fi

echo "[*] Running Ghidra headless (this can take several minutes on a big image)"
analyzeHeadless "$PROJ_DIR" "$PROJ_NAME" \
  -import "$OUT/$PRIMARY_FILE" \
  -loader BinaryLoader \
  -loader-baseAddr "$PRIMARY_BASE" \
  -processor "$LANG" \
  -scriptPath "$SCRIPTS" \
  -preScript AddSegments.java "$OUT/segments.tsv" \
  -postScript Enrich.java "$OUT" \
  -postScript ExportArtifacts.java "$OUT" \
  $KEEP 2>&1 | grep -viE "^(INFO|WARN|Using|Picked|OpenJDK|ERROR REPORT|classpath)" | tail -40 || true

echo
if [ -f "$OUT/decompiled.c" ]; then
  echo "[+] Ghidra analysis complete:"
  echo "    reports/ghidra/decompiled.c        decompiled C for every function"
  echo "    reports/ghidra/functions.txt       function list (addr, name, size)"
  echo "    reports/ghidra/symbols.txt         symbol table"
  echo "    reports/ghidra/strings-ghidra.txt  defined strings with addresses"
  echo "    reports/ghidra/xref-strings.txt    string -> functions that use it"
  echo "    reports/ghidra/func-strings.txt    function -> its strings (tags/messages)"
  wc -l "$OUT/functions.txt" 2>/dev/null | awk '{print "    ("$1" functions)"}'
  echo
  echo "[*] Triaging the decompilation into a ranked shortlist"
  gh-leads.py "$OUT" || echo "[!] lead triage skipped (see above)"
  if [ -z "$KEEP" ]; then
    echo
    echo "[+] Project kept at ${PROJ_DIR#"$WORK"/}/${PROJ_NAME}.gpr"
    echo "    Open it directly in the GUI with [34] - already mapped, analysed and named."
  fi
else
  echo "[!] No decompiled.c produced - check the headless output above."
  echo "    If the image is encrypted, disassembly is not meaningful."
fi
