#!/usr/bin/env bash
# First look at a dump: what is it, is it readable, and where is the content.
# Everything here is offline and read-only.

source /opt/re/lib/common.sh
init_workspace

DUMP="${1:-$DIR_DUMPS/flash_full.bin}"
[ -f "$DUMP" ] || die "No dump at ${DUMP#$WORK/}. Acquire one first."

REPORT="$DIR_REPORTS/triage.txt"

{
  hr
  echo "TRIAGE  $(basename "$DUMP")  run $RUN_ID"
  hr
  echo
  echo "### file"
  ls -l "$DUMP" | awk '{print "  size: "$5" bytes"}'
  echo "  sha256: $(sha256sum "$DUMP" | awk '{print $1}')"
  file -b "$DUMP" | sed 's/^/  type: /'
  echo

  echo "### entropy map (64 KiB blocks)"
  python3 - "$DUMP" <<'PY'
import sys, espfmt
data = open(sys.argv[1], "rb").read()
BLOCK = 64 * 1024
bars = " .:-=+*#%@"
row = []
high = 0
for i in range(0, len(data), BLOCK):
    e = espfmt.entropy(data[i:i + BLOCK])
    if e > 7.5:
        high += 1
    row.append(bars[min(int(e / 8 * (len(bars) - 1)), len(bars) - 1)])
# 64 blocks per line = 4 MiB of flash per two lines, readable in a terminal.
for i in range(0, len(row), 64):
    print("  0x%06x  %s" % (i * BLOCK, "".join(row[i:i + 64])))
print()
print("  legend: ' '=empty  '.'=low  '@'=maximum (encrypted/compressed)")
print("  %d of %d blocks are high entropy" % (high, len(row)))
if high > len(row) * 0.8:
    print("  [!] Almost everything is high entropy - this dump is probably encrypted.")
PY
  echo

  echo "### partition table"
  esp-parts.py "$DUMP" 2>&1 | sed 's/^/  /'
  echo

  echo "### ESP images found"
  python3 - "$DUMP" <<'PY'
import sys, espfmt
data = open(sys.argv[1], "rb").read()
imgs = espfmt.find_images(data)
if not imgs:
    print("  none found")
for img in imgs:
    print("  0x%08x  %-10s  %d segments  entry 0x%08x  flash %s/%s/%s"
          % (img.offset, img.chip, img.segment_count, img.entry_addr,
             img.flash_size, img.flash_mode, img.flash_freq))
    d = img.app_desc
    if d:
        print("      project '%s'  version '%s'  idf %s  built %s %s"
              % (d.project_name, d.version, d.idf_ver, d.date, d.time))
        if d.secure_version:
            print("      anti-rollback secure_version=%d" % d.secure_version)
    for s in img.segments:
        print("      seg%d load=0x%08x len=0x%-6x entropy=%.2f"
              % (s.index, s.load_addr, s.length, s.entropy))
PY
  echo

  echo "### binwalk signatures"
  if command -v binwalk >/dev/null 2>&1; then
    binwalk "$DUMP" 2>/dev/null | head -60 | sed 's/^/  /'
  else
    echo "  binwalk not available"
  fi
} 2>&1 | tee "$REPORT"

record "triage" "dump=${DUMP#$WORK/}"
register_artifact "$REPORT"
ok "Triage written to reports/triage.txt"
