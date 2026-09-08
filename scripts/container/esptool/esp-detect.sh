#!/usr/bin/env bash
# Identify the badge: chip, revision, MAC, flash geometry, security state.
# Read-only. This is always the first thing to run on an unknown target.

source /opt/re/lib/common.sh
init_workspace
require_port

RAW="$DIR_META/esptool_detect.txt"

probe() {
  local label="$1"; shift
  hr
  echo "### $label"
  hr
  # A failure here is informative, not fatal: get-security-info does not exist
  # on the original ESP32, and a read-protected chip refuses some queries.
  if ! "$@" 2>&1; then
    echo "(command failed or is unsupported on this target)"
  fi
  echo
}

log "Probing badge on $SERIAL_PORT (chip=$CHIP)"
{
  echo "# esptool detection run $RUN_ID"
  echo "# port=$SERIAL_PORT chip=$CHIP"
  echo
  probe "chip-id"       esp chip-id
  probe "flash-id"      esp flash-id
  probe "read-mac"      esp read-mac
  probe "security-info" esp get-security-info
} 2>&1 | tee "$RAW"

esp-meta.py "$RAW" || warn "Could not build target.json from the probe output"

record "detect" "port=$SERIAL_PORT"
register_artifact "$RAW"
hr
ok "Detection complete. Summary: $DIR_META/target.json"
