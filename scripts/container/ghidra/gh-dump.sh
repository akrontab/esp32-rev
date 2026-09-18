#!/usr/bin/env bash
# Headless Ghidra over a WHOLE flash dump, not just one app image.
#
# gh-analyze.sh ([33]) decompiles a single app image. This finds every
# code-bearing image in the dump - the 2nd-stage bootloader plus each app slot
# that actually holds firmware - and runs that same segment-accurate pipeline
# over each one, into its own subdir:
#
#   reports/ghidra/images.json          the inventory (all candidates + reasons)
#   reports/ghidra/<image>/decompiled.c etc. per image (bootloader, app0, ...)
#   reports/ghidra/dump-summary.txt     one line per analysed image
#
# Blank slots (no OTA image) and anything without a valid header are listed and
# skipped, not analysed. Offline; reads only the workspace.

set -euo pipefail
WORK="${WORK:-/work}"
OUT="$WORK/reports/ghidra"
DUMP="${1:-$WORK/dumps/flash_full.bin}"

if [ ! -f "$DUMP" ]; then
  echo "[x] flash dump not found: $DUMP"
  echo "    Acquire a full dump first ([9]/[10]), or pass a path to a dump."
  exit 1
fi

mkdir -p "$OUT"
echo "[*] Inventorying code images in $(basename "$DUMP")"
gh-images.py "$DUMP"

# Emit "label<TAB>offset<TAB>image_length" for each loadable image.
mapfile -t ROWS < <(python3 - "$OUT/images.json" <<'PY'
import json, sys
inv = json.load(open(sys.argv[1]))
for i in inv["images"]:
    if i["loadable"]:
        print("%s\t%d\t%d" % (i["label"], i["offset"], i["image_length"]))
PY
)

if [ "${#ROWS[@]}" -eq 0 ]; then
  echo "[!] No loadable images found in the dump - nothing to analyse."
  echo "    (An encrypted flash dumps as ciphertext; check the eFuse posture.)"
  exit 0
fi

SUMMARY="$OUT/dump-summary.txt"
: > "$SUMMARY"
echo "# Ghidra full-dump analysis of $(basename "$DUMP")" >> "$SUMMARY"
echo >> "$SUMMARY"

echo "[*] ${#ROWS[@]} loadable image(s) to analyse."
for row in "${ROWS[@]}"; do
  label="${row%%$'\t'*}"
  rest="${row#*$'\t'}"
  offset="${rest%%$'\t'*}"
  length="${rest#*$'\t'}"

  sub="$OUT/$label"
  mkdir -p "$sub"
  carved="$sub/${label}.bin"

  echo
  echo "============================================================"
  echo "[*] $label  (offset $offset, $length bytes) -> reports/ghidra/$label/"
  echo "============================================================"

  # Carve this image out of the dump as a standalone file, then run the exact
  # same prep -> load -> export pipeline [33] uses, redirected to the subdir.
  python3 - "$DUMP" "$carved" "$offset" "$length" <<'PY'
import sys
dump, out, off, length = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with open(dump, "rb") as f:
    f.seek(off)
    open(out, "wb").write(f.read(length))
PY

  if GHIDRA_OUT="$sub" gh-analyze.sh "$carved"; then
    if [ -f "$sub/functions.txt" ]; then
      n=$(wc -l < "$sub/functions.txt" | tr -d ' ')
      printf "%-14s %-11s %6s functions   reports/ghidra/%s/\n" \
        "$label" "$offset" "$n" "$label" >> "$SUMMARY"
    else
      printf "%-14s %-11s   (no output - see log above)\n" "$label" "$offset" >> "$SUMMARY"
    fi
  else
    printf "%-14s %-11s   (analysis failed - see log above)\n" "$label" "$offset" >> "$SUMMARY"
  fi
done

echo
echo "[+] Full-dump analysis complete. Per-image reports under reports/ghidra/<image>/."
echo "    Inventory: reports/ghidra/images.json"
echo "    Summary:   reports/ghidra/dump-summary.txt"
echo
cat "$SUMMARY"
