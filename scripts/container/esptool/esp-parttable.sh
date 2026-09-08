#!/usr/bin/env bash
# Read and decode the partition table straight off the badge.
#
# Cheap (4 KiB) and high value: it tells you where the app lives, whether
# there is OTA, and whether there is a filesystem worth carving - before you
# commit to a multi-minute full dump.

source /opt/re/lib/common.sh
init_workspace
require_port

OUT="$DIR_PARTS/partition-table.bin"

log "Reading partition table from 0x8000"
if ! esp --baud "$BAUD" read-flash 0x8000 0x1000 "$OUT"; then
  warn "Read failed at ${BAUD} baud - retrying at 115200"
  esp --baud 115200 read-flash 0x8000 0x1000 "$OUT" || die "Could not read the partition table."
fi

record "partition-table" "out=${OUT#$WORK/}"
register_artifact "$OUT"

esp-parts.py "$OUT"
