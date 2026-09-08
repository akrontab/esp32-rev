#!/usr/bin/env bash
# Read flash to a file, hash it, and record provenance.
#
#   esp-dump.sh                      full flash (size auto-detected)
#   esp-dump.sh 0x9000 0x6000 nvs    a single region
#
# Read-only: this script never writes to or erases the badge.

source /opt/re/lib/common.sh
init_workspace
require_port

ADDR="${1:-0}"
SIZE="${2:-}"
NAME="${3:-}"

detect_flash_bytes() {
  # Prefer what detection already learned, so we do not re-probe needlessly.
  local meta="$DIR_META/target.json"
  if [ -f "$meta" ]; then
    local b
    b="$(python3 -c "import json,sys; print(json.load(open('$meta')).get('flash_bytes') or '')" 2>/dev/null || true)"
    if [ -n "$b" ]; then echo "$b"; return 0; fi
  fi
  log "Flash size unknown - probing" >&2
  local out size
  out="$(esp flash-id 2>&1 || true)"
  size="$(echo "$out" | sed -n 's/.*Detected flash size:\s*\([0-9]\+[KM]B\).*/\1/p' | head -1)"
  case "$size" in
    256KB) echo $((256*1024));; 512KB) echo $((512*1024));;
    1MB)  echo $((1*1024*1024));;  2MB)  echo $((2*1024*1024));;
    4MB)  echo $((4*1024*1024));;  8MB)  echo $((8*1024*1024));;
    16MB) echo $((16*1024*1024));; 32MB) echo $((32*1024*1024));;
    64MB) echo $((64*1024*1024));;
    *)    warn "Could not detect flash size; assuming 4MB. Override with size argument." >&2
          echo $((4*1024*1024));;
  esac
}

if [ -z "$SIZE" ]; then
  SIZE="$(detect_flash_bytes)"
  NAME="${NAME:-flash_full}"
  ADDR=0
else
  NAME="${NAME:-region_${ADDR}_${SIZE}}"
fi

OUT="$DIR_DUMPS/${NAME}.bin"
HUMAN=$(( SIZE / 1024 ))

log "Reading ${HUMAN} KiB from $ADDR at ${BAUD} baud -> dumps/${NAME}.bin"
warn "Do not unplug the badge until this finishes."

# High baud rates fail on long cables and cheap bridges; fall back rather than
# leaving the operator with a truncated dump and no explanation.
if ! esp --baud "$BAUD" read-flash "$ADDR" "$SIZE" "$OUT"; then
  warn "Read failed at ${BAUD} baud - retrying at 115200"
  rm -f "$OUT"
  if ! esp --baud 115200 read-flash "$ADDR" "$SIZE" "$OUT"; then
    die "Flash read failed. Check the cable, try holding BOOT, or see docs/troubleshooting."
  fi
fi

[ -s "$OUT" ] || die "Dump file is empty."

record "dump" "addr=$ADDR size=$SIZE out=${OUT#$WORK/} baud=$BAUD"
register_artifact "$OUT"

# A dump of nothing but erased flash usually means the read was refused or the
# chip is blank - flag it now rather than after an hour of fruitless analysis.
python3 - "$OUT" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
uniq = set(data)
if uniq <= {0xFF} or uniq <= {0x00}:
    print("[!] WARNING: dump is entirely blank (0xFF/0x00) - read was likely refused.")
else:
    import collections
    common = collections.Counter(data).most_common(1)[0]
    pct = 100.0 * common[1] / len(data)
    print("[*] most common byte 0x%02X covers %.1f%% of the dump" % (common[0], pct))
PY

ok "Dump complete: dumps/${NAME}.bin"
log "Next: run the analysis pipeline to carve and inspect it."
