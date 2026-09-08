#!/usr/bin/env bash
# Shared helpers for every containerised tool in this project.
# Sourced, never executed directly.

set -euo pipefail

WORK="${WORK:-/work}"                 # target workspace, bind-mounted from the host
TARGET="${TARGET:-unknown}"           # human name for the badge under test
SERIAL_PORT="${SERIAL_PORT:-}"        # /dev/ttyUSB0 style path inside the container
BAUD="${BAUD:-460800}"
CHIP="${CHIP:-auto}"

DIR_META="$WORK/meta"
DIR_DUMPS="$WORK/dumps"
DIR_PARTS="$WORK/parts"
DIR_EXTRACT="$WORK/extract"
DIR_REPORTS="$WORK/reports"
DIR_LOGS="$WORK/logs"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[-1]:-tool}")"

init_workspace() {
  mkdir -p "$DIR_META" "$DIR_DUMPS" "$DIR_PARTS" "$DIR_EXTRACT" "$DIR_REPORTS" "$DIR_LOGS"
}

# --- output -----------------------------------------------------------------
# Colour only when attached to a terminal, so piped logs stay clean.
if [ -t 1 ]; then
  C_RST=$'\033[0m'; C_INF=$'\033[36m'; C_OK=$'\033[32m'; C_WRN=$'\033[33m'; C_ERR=$'\033[31m'
else
  C_RST=''; C_INF=''; C_OK=''; C_WRN=''; C_ERR=''
fi

log()  { printf '%s[*]%s %s\n' "$C_INF" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_OK"  "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_WRN" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; exit 1; }
hr()   { printf -- '---------------------------------------------------------------\n'; }

# --- provenance -------------------------------------------------------------
# Append one JSON line per action so the whole engagement is replayable and
# every artefact can be traced back to the command that produced it.
record() {
  local action="$1"; shift
  local detail="${1:-}"
  init_workspace
  python3 - "$action" "$detail" <<'PY' >> "$DIR_LOGS/actions.jsonl"
import json, os, sys, datetime
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "target": os.environ.get("TARGET", "unknown"),
    "tool": os.environ.get("SCRIPT_NAME", os.path.basename(sys.argv[0] or "tool")),
    "action": sys.argv[1],
    "detail": sys.argv[2],
    "port": os.environ.get("SERIAL_PORT", ""),
    "chip": os.environ.get("CHIP", ""),
}))
PY
}

# Hash an artefact and register it in the workspace checksum ledger.
register_artifact() {
  local path="$1"
  [ -f "$path" ] || return 0
  local sum size
  sum="$(sha256sum "$path" | awk '{print $1}')"
  size="$(stat -c %s "$path")"
  # Keep one line per artefact; replace any previous entry for the same path.
  local ledger="$DIR_META/artifacts.sha256"
  touch "$ledger"
  grep -v -F "  ${path#$WORK/}" "$ledger" > "$ledger.tmp" 2>/dev/null || true
  mv "$ledger.tmp" "$ledger"
  printf '%s  %s\n' "$sum" "${path#$WORK/}" >> "$ledger"
  ok "$(basename "$path")  ${size} bytes  sha256=${sum:0:16}..."
  record "artifact" "${path#$WORK/} sha256=$sum size=$size"
}

require_port() {
  [ -n "$SERIAL_PORT" ] || die "No serial port set. Attach the badge first (control plane -> USB device manager)."
  [ -e "$SERIAL_PORT" ] || die "Serial port $SERIAL_PORT is not present inside the container. Re-attach the device."
}

# esptool wrapper: consistent chip/port/baud handling in one place.
esp() {
  local args=(--port "$SERIAL_PORT")
  [ "$CHIP" != "auto" ] && args+=(--chip "$CHIP")
  esptool "${args[@]}" "$@"
}
