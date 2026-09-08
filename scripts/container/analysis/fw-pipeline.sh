#!/usr/bin/env bash
# Run the whole offline analysis chain on a dump, in dependency order.
# Safe to re-run: each stage rewrites its own outputs.

source /opt/re/lib/common.sh
init_workspace

DUMP="${1:-$DIR_DUMPS/flash_full.bin}"
[ -f "$DUMP" ] || die "No dump at ${DUMP#$WORK/}. Acquire one first."

STARTED="$(date -u +%s)"

stage() { hr; log "$1"; hr; }

stage "1/5  Triage"
fw-triage.sh "$DUMP" >/dev/null || warn "triage reported problems"
tail -n 20 "$DIR_REPORTS/triage.txt" 2>/dev/null

stage "2/5  Splitting partitions"
fw-split.py "$DUMP" || warn "split reported problems"

stage "3/5  Extracting filesystems"
fw-fs.py || warn "filesystem extraction reported problems"

stage "4/5  Dumping NVS"
fw-nvs.py || warn "NVS dump reported problems"

stage "5/5  Hunting for flags and secrets"
fw-hunt.sh >/dev/null || warn "hunt reported problems"
sed -n '/highest-value leads/,$p' "$DIR_REPORTS/hunt.txt" 2>/dev/null | head -30

ELAPSED=$(( $(date -u +%s) - STARTED ))
record "pipeline" "elapsed=${ELAPSED}s dump=${DUMP#$WORK/}"

hr
ok "Analysis pipeline finished in ${ELAPSED}s"
echo
echo "  reports/triage.txt        what the dump is, entropy, images"
echo "  reports/partitions.txt    partition layout"
echo "  reports/nvs-*.txt         key/value contents, including erased entries"
echo "  reports/hunt.txt          pattern hits"
echo "  reports/strings.txt       every string, attributed to its file"
echo "  parts/                    one file per partition"
echo "  extract/                  files recovered from filesystems"
echo
log "Record what you find in NOTES.md as you go."
