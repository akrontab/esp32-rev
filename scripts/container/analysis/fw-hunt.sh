#!/usr/bin/env bash
# Hunt for the things that win challenges: flags, credentials, keys, URLs.
#
# Runs over the raw dump, every carved partition and every extracted file.
# Edit /work/patterns.txt to add challenge-specific patterns; if that file
# exists it is used instead of the built-in list.

source /opt/re/lib/common.sh
init_workspace

REPORT="$DIR_REPORTS/hunt.txt"
STRINGS_OUT="$DIR_REPORTS/strings.txt"
MINLEN="${MINLEN:-6}"

# Note: these are Rust-regex (ripgrep) syntax, which rejects pointless escapes
# such as \" with a parse error rather than ignoring them. Quote characters go
# into character classes bare.
DEFAULT_PATTERNS='
flag\{[^}]{0,120}\}
FLAG\{[^}]{0,120}\}
CTF\{[^}]{0,120}\}
[A-Za-z0-9_]{2,20}\{[A-Za-z0-9_@!$%^&*()+=./-]{4,80}\}
-----BEGIN [A-Z ]*PRIVATE KEY-----
-----BEGIN CERTIFICATE-----
(password|passwd|passphrase|secret|token|api[_-]?key|auth)["'\'':= ]{1,4}[^\s"'\'',;]{4,80}
(ssid|wifi|psk)["'\'':= ]{1,4}[^\s"'\'',;]{2,64}
[a-z][a-z0-9+.-]{2,10}://[^\s"'\''<>]{4,120}
[A-Za-z0-9+/]{40,}={0,2}
(eyJ[A-Za-z0-9_-]{10,}\.){2}[A-Za-z0-9_-]{10,}
([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}
[0-9a-f]{32,64}
'

PAT_FILE="$WORK/patterns.txt"
if [ -f "$PAT_FILE" ]; then
  log "Using custom patterns from patterns.txt"
else
  PAT_FILE="$(mktemp)"
  echo "$DEFAULT_PATTERNS" | grep -v '^[[:space:]]*$' > "$PAT_FILE"
fi

# Search the raw dump plus anything already carved or extracted. Raw flash is
# searched too, because a string may live in a region no partition claims.
SEARCH_PATHS=()
[ -d "$DIR_DUMPS" ]   && SEARCH_PATHS+=("$DIR_DUMPS")
[ -d "$DIR_PARTS" ]   && SEARCH_PATHS+=("$DIR_PARTS")
[ -d "$DIR_EXTRACT" ] && SEARCH_PATHS+=("$DIR_EXTRACT")
[ ${#SEARCH_PATHS[@]} -gt 0 ] || die "Nothing to search - acquire and split a dump first."

# Check the tools up front. The per-file calls below redirect stderr away to
# hide binary-file noise, which would otherwise also hide a missing tool.
for tool in strings rg; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is missing from this image - rebuild it."
done

ERRFILE="$(mktemp)"
trap 'rm -f "$ERRFILE"' EXIT

log "Extracting strings (min length $MINLEN)"
: > "$STRINGS_OUT"
find "${SEARCH_PATHS[@]}" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
  rel="${f#$WORK/}"
  # Both encodings: ESP firmware mixes 8-bit and UTF-16 literals.
  strings -a -n "$MINLEN" "$f"        2>/dev/null | sed "s|^|$rel: |"
  strings -a -n "$MINLEN" -e l "$f"   2>/dev/null | sed "s|^|$rel(utf16): |"
done >> "$STRINGS_OUT"

TOTAL=$(wc -l < "$STRINGS_OUT")
log "$TOTAL strings extracted -> reports/strings.txt"

{
  hr
  echo "HUNT  run $RUN_ID   ($TOTAL strings searched)"
  hr
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    echo
    echo "### /$pat/"
    # rg exits 1 for "no match" (normal) and 2 for a bad pattern. Those must
    # not look alike: a malformed custom pattern silently reporting "nothing
    # here" is how you miss the flag.
    rc=0
    raw="$(rg --no-line-number --no-heading -o -N -e "$pat" "$STRINGS_OUT" 2>"$ERRFILE")" || rc=$?
    if [ "$rc" -ge 2 ]; then
      echo "  [!] INVALID PATTERN - not searched:"
      sed 's/^/      /' "$ERRFILE" | head -4
      continue
    fi
    matches="$(printf '%s' "$raw" | sort -u | head -40)"
    if [ -n "$matches" ]; then
      echo "$matches" | sed 's/^/  /'
      total="$(printf '%s' "$raw" | grep -c . || true)"
      echo "  ($total total matches)"
    else
      echo "  (no matches)"
    fi
  done < "$PAT_FILE"

  echo
  hr
  echo "### highest-value leads"
  hr
  # A flag-shaped string is worth showing with its source file.
  leads="$(rg -n --no-heading -e 'flag\{|FLAG\{|CTF\{' "$STRINGS_OUT" 2>/dev/null | head -20 || true)"
  if [ -n "$leads" ]; then
    echo "$leads" | sed 's/^/  /'
  else
    echo "  none - widen the search with MINLEN=4, or check reports/strings.txt by hand"
  fi
} 2>&1 | tee "$REPORT"

record "hunt" "strings=$TOTAL"
register_artifact "$REPORT"
register_artifact "$STRINGS_OUT"
ok "Hunt complete -> reports/hunt.txt"
