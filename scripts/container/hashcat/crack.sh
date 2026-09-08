#!/usr/bin/env bash
# Local GPU cracking with a sensible escalating attack sequence.
#
#   crack.sh -m <mode> <hashfile> [--custom]
#
# Attack order (each stops early if all hashes crack):
#   1. rockyou straight
#   2. rockyou + best64 rules      (fast, high yield)
#   3. rockyou + OneRuleToRuleThemAll  (slower, much broader)
#   4. a target-derived wordlist from the badge's own strings, if --custom
#
# Per the project's cracking workflow: this is the FIRST line. If nothing
# cracks in ~30 minutes here, escalate to the Linode rig (terraform, by hand) -
# see docs/hash-cracking.md. This script prints that cue when it gives up.

source /opt/re/lib/common.sh 2>/dev/null || true
WORK="${WORK:-/work}"
ROCKYOU=/opt/wordlists/rockyou.txt
RULES_BEST64="${HASHCAT_RULES_DIR}/best64.rule"
RULES_ONE=/opt/rules/OneRuleToRuleThemAll.rule
POT="$WORK/reports/cracked.potfile"

MODE=""; HASHFILE=""; CUSTOM=0
while [ $# -gt 0 ]; do
  case "$1" in
    -m) MODE="$2"; shift 2;;
    --custom) CUSTOM=1; shift;;
    *) HASHFILE="$1"; shift;;
  esac
done

[ -n "$MODE" ] || { echo "usage: crack.sh -m <hashcat-mode> <hashfile> [--custom]"; exit 2; }
[ -f "$HASHFILE" ] || { echo "[x] hash file not found: $HASHFILE"; exit 1; }
mkdir -p "$WORK/reports"

command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | sed 's/^/[*] GPU: /'

HC=(hashcat -m "$MODE" --potfile-path "$POT" -O -w 3)

remaining() { hashcat -m "$MODE" "$HASHFILE" --potfile-path "$POT" --show 2>/dev/null | wc -l; }
total=$(grep -c . "$HASHFILE")

run() {
  local label="$1"; shift
  local done; done=$(remaining)
  if [ "$done" -ge "$total" ]; then return 0; fi
  hr 2>/dev/null || echo "---"
  log "attack: $label" 2>/dev/null || echo "[*] attack: $label"
  "${HC[@]}" "$HASHFILE" "$@" 2>&1 | grep -iE "Recovered|Status|Speed|Cracked" | head -4 || true
}

build_custom() {
  # A wordlist from the badge itself: firmware strings + BLE values, deduped.
  local cw="$WORK/reports/custom-wordlist.txt"
  { [ -f "$WORK/reports/strings.txt" ] && cut -d: -f2- "$WORK/reports/strings.txt";
    [ -d "$WORK/extract" ] && grep -rhoE '[[:print:]]{3,40}' "$WORK/extract" 2>/dev/null;
  } | tr -s ' ' '\n' | sed 's/[^[:print:]]//g' | awk 'length>=3 && length<=40' | sort -u > "$cw"
  echo "$cw"
}

START=$(date +%s)
run "rockyou (straight)"            "$ROCKYOU"
[ -f "$RULES_BEST64" ] && run "rockyou + best64"  "$ROCKYOU" -r "$RULES_BEST64"
[ -f "$RULES_ONE" ]    && run "rockyou + OneRule"  "$ROCKYOU" -r "$RULES_ONE"
if [ "$CUSTOM" = 1 ]; then
  CW=$(build_custom)
  run "target-derived wordlist + best64" "$CW" -r "$RULES_BEST64"
fi

ELAPSED=$(( $(date +%s) - START ))
hr 2>/dev/null || echo "==="
echo "[*] cracked so far:"
hashcat -m "$MODE" "$HASHFILE" --potfile-path "$POT" --show 2>/dev/null | tee "$WORK/reports/cracked.txt"
got=$(remaining)
echo
echo "[*] $got / $total cracked in ${ELAPSED}s   (results: reports/cracked.txt)"
if [ "$got" -lt "$total" ]; then
  echo "[!] Not everything cracked locally."
  echo "    Per the workflow, if this pass ran ~30 min with no joy, escalate to"
  echo "    the Linode rig for deep brute-force / slow-hash work:"
  echo "      1. cd linode && terraform apply        (you run this)"
  echo "      2. push $HASHFILE and run hashcat there with a mask or big wordlist"
  echo "      3. terraform destroy                   (stop billing)"
  echo "    See docs/hash-cracking.md for the exact commands."
fi
