#!/usr/bin/env bash
# Identify hashes and map them to hashcat modes. Always run this first - the
# entire cracking strategy depends on the algorithm, and a 40-hex string is
# SHA-1 (-m 100) OR RIPEMD-160 (-m 6000), which need different attacks.
#
#   hash-id.sh <hash-or-file>      identify one hash, or every line of a file
#   hash-id.sh --scan              scan the workspace for hash-shaped strings

source /opt/re/lib/common.sh 2>/dev/null || true
WORK="${WORK:-/work}"

scan_workspace() {
  # Pull hash-shaped tokens out of everything already gathered: strings,
  # reports, extracted files. Length-anchored so we do not drown in noise.
  local out="$WORK/reports/hashes-found.txt"
  mkdir -p "$WORK/reports"
  {
    for f in "$WORK"/reports/strings.txt "$WORK"/reports/ble-gatt.txt \
             "$WORK"/reports/nvs-*.txt "$WORK"/extract/ble/*; do
      [ -f "$f" ] || continue
      grep -oiE '\b[0-9a-f]{32}\b|\b[0-9a-f]{40}\b|\b[0-9a-f]{56}\b|\b[0-9a-f]{64}\b|\b[0-9a-f]{96}\b|\b[0-9a-f]{128}\b' "$f" 2>/dev/null
      # crypt-style and bcrypt markers
      grep -oE '\$[0-9a-z]{1,3}\$[^[:space:]"]{10,}' "$f" 2>/dev/null
    done
  } | sort -u > "$out"
  local n; n=$(grep -c . "$out" || true)
  echo "[+] $n candidate hash(es) -> reports/hashes-found.txt"
  [ "$n" -gt 0 ] && identify_lines "$out"
}

hint_mode() {
  # Cheap length-based hashcat-mode hints, shown alongside name-that-hash.
  local h="$1" len=${#1}
  case "$h" in
    \$2[aby]\$*) echo "  -> bcrypt: hashcat -m 3200";;
    \$1\$*)      echo "  -> md5crypt: hashcat -m 500";;
    \$6\$*)      echo "  -> sha512crypt: hashcat -m 1800";;
    \$5\$*)      echo "  -> sha256crypt: hashcat -m 7400";;
    *)
      case "$len" in
        32)  echo "  -> 32 hex: MD5 (-m 0) | NTLM (-m 1000) | MD4 (-m 900)";;
        40)  echo "  -> 40 hex: SHA-1 (-m 100) | RIPEMD-160 (-m 6000)";;
        56)  echo "  -> 56 hex: SHA-224 (-m 1300)";;
        64)  echo "  -> 64 hex: SHA-256 (-m 1400) | SHA3-256 (-m 17400)";;
        96)  echo "  -> 96 hex: SHA-384 (-m 10800)";;
        128) echo "  -> 128 hex: SHA-512 (-m 1700) | SHA3-512 (-m 17600)";;
        *)   echo "  -> length $len: see name-that-hash output above";;
      esac;;
  esac
}

identify_lines() {
  local file="$1"
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    echo
    echo "### $h"
    # name-that-hash gives ranked candidates with hashcat modes.
    if command -v nth >/dev/null 2>&1; then
      nth -t "$h" -a 2>/dev/null | grep -iE "hashcat|Most|Least|^\s+[A-Z]" | head -8
    elif command -v name-that-hash >/dev/null 2>&1; then
      name-that-hash -t "$h" 2>/dev/null | head -8
    fi
    hint_mode "$h"
  done < "$file"
}

case "${1:-}" in
  ""|--scan) scan_workspace ;;
  *)
    if [ -f "$1" ]; then identify_lines "$1"
    else printf '%s\n' "$1" > /tmp/one.hash; identify_lines /tmp/one.hash; fi
    ;;
esac
