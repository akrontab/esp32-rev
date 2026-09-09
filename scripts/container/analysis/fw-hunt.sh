#!/usr/bin/env bash
# Hunt for the things that win challenges: flags, credentials, keys, URLs.
#
# Runs over the raw dump, every carved partition and every extracted file.
#
# Patterns come from two places and are ADDITIVE by default:
#   1. workspace/<target>/patterns.txt   - yours, searched first
#   2. the built-in list below           - generic credential/key/flag shapes
# Adding the event's flag format should never cost you the generic patterns,
# so a custom file extends the defaults rather than replacing them. Put
# '#!replace' on a line of patterns.txt when you deliberately want a narrow
# search with the defaults switched off.

source /opt/re/lib/common.sh
init_workspace

REPORT="$DIR_REPORTS/hunt.txt"
STRINGS_OUT="$DIR_REPORTS/strings.txt"
MINLEN="${MINLEN:-6}"

# Note: these are Rust-regex (ripgrep) syntax, which rejects pointless escapes
# such as \" with a parse error rather than ignoring them. Quote characters go
# into character classes bare. There is no lookaround and no backreference.
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

# Check the tools up front. The per-file calls below redirect stderr away to
# hide binary-file noise, which would otherwise also hide a missing tool.
for tool in strings rg; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is missing from this image - rebuild it."
done

ERRFILE="$(mktemp)"
CUSTOM_CLEAN="$(mktemp)"
DEFAULT_CLEAN="$(mktemp)"
trap 'rm -f "$ERRFILE" "$CUSTOM_CLEAN" "$DEFAULT_CLEAN"' EXIT

# --- assemble the pattern set ----------------------------------------------

strip_comments() { grep -v -E '^[[:space:]]*(#|$)' "$1" || true; }

CUSTOM_FILE="$WORK/patterns.txt"
MODE="append"
N_CUSTOM=0

if [ -f "$CUSTOM_FILE" ]; then
  strip_comments "$CUSTOM_FILE" > "$CUSTOM_CLEAN"
  N_CUSTOM="$(grep -c . "$CUSTOM_CLEAN" || true)"
  # The directive is itself a comment, so it never reaches the pattern list.
  if grep -q -E '^[[:space:]]*#!replace' "$CUSTOM_FILE"; then
    MODE="replace"
  fi
fi

echo "$DEFAULT_PATTERNS" | grep -v -E '^[[:space:]]*$' > "$DEFAULT_CLEAN"
if [ "$MODE" = "replace" ]; then
  : > "$DEFAULT_CLEAN"
elif [ "$N_CUSTOM" -gt 0 ]; then
  # Drop any default the custom file already states verbatim, so copying the
  # defaults across does not produce duplicate sections.
  grep -v -x -F -f "$CUSTOM_CLEAN" "$DEFAULT_CLEAN" > "$DEFAULT_CLEAN.tmp" 2>/dev/null || true
  mv "$DEFAULT_CLEAN.tmp" "$DEFAULT_CLEAN" 2>/dev/null || true
fi
N_DEFAULT="$(grep -c . "$DEFAULT_CLEAN" || true)"

if [ "$N_CUSTOM" -gt 0 ]; then
  if [ "$MODE" = "replace" ]; then
    log "patterns.txt: $N_CUSTOM custom patterns, defaults DISABLED (#!replace)"
  else
    log "patterns.txt: $N_CUSTOM custom patterns + $N_DEFAULT defaults"
  fi
else
  log "using $N_DEFAULT built-in patterns (add workspace/patterns.txt to extend)"
fi

# --- extract strings --------------------------------------------------------

log "Extracting strings (min length $MINLEN)"
: > "$STRINGS_OUT"

# Search the raw dump plus anything already carved or extracted. Raw flash is
# searched too, because a string may live in a region no partition claims.
SEARCH_PATHS=()
[ -d "$DIR_DUMPS" ]   && SEARCH_PATHS+=("$DIR_DUMPS")
[ -d "$DIR_PARTS" ]   && SEARCH_PATHS+=("$DIR_PARTS")
[ -d "$DIR_EXTRACT" ] && SEARCH_PATHS+=("$DIR_EXTRACT")
[ ${#SEARCH_PATHS[@]} -gt 0 ] || die "Nothing to search - acquire and split a dump first."

find "${SEARCH_PATHS[@]}" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
  rel="${f#$WORK/}"
  # Both encodings: ESP firmware mixes 8-bit and UTF-16 literals.
  strings -a -n "$MINLEN" "$f"      2>/dev/null | sed "s|^|$rel: |"
  strings -a -n "$MINLEN" -e l "$f" 2>/dev/null | sed "s|^|$rel(utf16): |"
done >> "$STRINGS_OUT"

TOTAL=$(wc -l < "$STRINGS_OUT")
log "$TOTAL strings extracted -> reports/strings.txt"

# --- search -----------------------------------------------------------------

hunt_patterns() {
  # $1 = origin label shown against each section, $2 = file of patterns
  local origin="$1" file="$2" pat rc raw matches total
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue ;; esac
    echo
    echo "### [$origin] /$pat/"

    # rg exits 1 for "no match" (normal) and 2 for a bad pattern. Those must
    # not look alike: a malformed pattern silently reporting "nothing here" is
    # how you miss the flag.
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
  done < "$file"
}

{
  hr
  echo "HUNT  run $RUN_ID   ($TOTAL strings searched)"
  if [ "$N_CUSTOM" -gt 0 ]; then
    echo "patterns: $N_CUSTOM custom + $N_DEFAULT default (mode: $MODE)"
  else
    echo "patterns: $N_DEFAULT default"
  fi
  hr

  # Custom patterns first - they are the ones you came here to check.
  if [ "$N_CUSTOM" -gt 0 ]; then
    hunt_patterns custom "$CUSTOM_CLEAN"
  fi
  if [ "$N_DEFAULT" -gt 0 ]; then
    hunt_patterns default "$DEFAULT_CLEAN"
  fi

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

record "hunt" "strings=$TOTAL custom=$N_CUSTOM default=$N_DEFAULT mode=$MODE"
register_artifact "$REPORT"
register_artifact "$STRINGS_OUT"
ok "Hunt complete -> reports/hunt.txt"

# Categorise the same strings into signal vs noise buckets - turns the 10k-line
# strings.txt into a few hundred triaged leads.
if command -v fw-leads.py >/dev/null 2>&1; then
  fw-leads.py >/dev/null 2>&1 && register_artifact "$DIR_REPORTS/leads.txt" \
    && ok "Categorised leads -> reports/leads.txt"
fi
