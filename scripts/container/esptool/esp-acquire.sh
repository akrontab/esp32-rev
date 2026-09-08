#!/usr/bin/env bash
# One-shot acquisition: everything you want from the hardware, in order,
# before you start thinking. Safe to re-run; each step overwrites its own
# artefact and appends to the action log.
#
# Order matters: identify the chip, then read the eFuses (which tell you
# whether a dump is even meaningful), then the cheap partition table, then
# the expensive full dump.

source /opt/re/lib/common.sh
init_workspace
require_port

STARTED="$(date -u +%s)"

step() {
  hr
  log "$1"
  hr
}

step "1/4  Identifying the chip"
esp-detect.sh || warn "detection had problems - continuing"

step "2/4  Reading eFuses / security posture"
esp-efuse.sh || warn "eFuse read had problems - continuing"

step "3/4  Reading the partition table"
esp-parttable.sh || warn "no readable partition table - continuing anyway"

# If flash encryption is on, say so loudly but still take the dump: the
# ciphertext is evidence, and some CTF tasks hand you the key later.
if [ -f "$DIR_META/target.json" ]; then
  if python3 -c "import json,sys; d=json.load(open('$DIR_META/target.json')); sys.exit(0 if d.get('flash_encryption_enabled') else 1)" 2>/dev/null; then
    warn "Flash encryption is enabled - the dump will be ciphertext."
    warn "Taking it anyway; see docs/playbook.md for the encrypted branch."
  fi
fi

step "4/4  Dumping full flash"
esp-dump.sh || die "Flash dump failed - the earlier artefacts are still saved."

ELAPSED=$(( $(date -u +%s) - STARTED ))
record "acquire" "elapsed=${ELAPSED}s"

hr
ok "Acquisition complete in ${ELAPSED}s"
echo
echo "  meta/target.json          chip, MAC, flash geometry"
echo "  meta/efuse_summary.txt    security posture"
echo "  reports/partitions.txt    partition layout"
echo "  dumps/flash_full.bin      full flash image"
echo "  meta/artifacts.sha256     hashes of everything above"
echo
log "You can unplug the badge now. Next: run the analysis pipeline."
