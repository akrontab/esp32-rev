#!/usr/bin/env bash
# Build a symbolised reference ELF from the arduino-esp32 core, so Ghidra can
# name the SDK functions in the stripped badge dump (see docs/name-recovery.md).
#
#   arduino-ref.sh [core-version] [chip] [profile]
#     core-version  arduino-esp32 version, e.g. 2.0.16 (empty = latest)
#     chip          esp32 / esp32s3 / esp32c3 ... (default: $CHIP or esp32s3)
#     profile       full (default; pulls in WiFi/BLE/ESP-NOW/mbedtls) | minimal
#
# Output goes to reference/arduino-esp32-<version>/ in the workspace:
#   reference.elf   the symbolised build - feed this to Ghidra FunctionID
#   REFERENCE.txt   what was built, and where the prebuilt libs are
#
# To match a different SDK, just re-run with another version arg. The badge's
# own IDF version is printed by the analysis pipeline (reports/triage.txt).
set -euo pipefail

WORK="${WORK:-/work}"
CORE_VERSION="${1:-}"
CHIP="${2:-${CHIP:-esp32s3}}"
PROFILE="${3:-full}"

CHIP="$(printf '%s' "$CHIP" | tr 'A-Z' 'a-z' | tr -d '-')"
BOARD="esp32:esp32:${CHIP}"

echo "[*] Updating the board index"
arduino-cli core update-index >/dev/null

if [ -n "$CORE_VERSION" ]; then SPEC="esp32:esp32@${CORE_VERSION}"; else SPEC="esp32:esp32"; fi
echo "[*] Installing core $SPEC  (cached across runs in the arduino volume)"
arduino-cli core install "$SPEC"

VER="$(arduino-cli core list 2>/dev/null | awk '$1=="esp32:esp32"{print $2}')"
VER="${VER:-${CORE_VERSION:-unknown}}"
OUT="$WORK/reference/arduino-esp32-${VER}"
mkdir -p "$OUT/ref" "$OUT/build"
echo "[*] Reference: arduino-esp32 $VER for $BOARD  ->  reference/arduino-esp32-${VER}/"

# The reference sketch. "full" references the subsystems a badge actually uses
# (WiFi, HTTP, ESP-NOW, BLE, mbedtls hashes/AES) so those SDK functions are
# linked in *with symbols*; "minimal" is a bare sketch if full won't compile on
# some core version.
if [ "$PROFILE" = "minimal" ]; then
    cat > "$OUT/ref/ref.ino" <<'INO'
void setup() { Serial.begin(115200); }
void loop() {}
INO
else
    cat > "$OUT/ref/ref.ino" <<'INO'
#include <Arduino.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <WebServer.h>
#include <esp_now.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <mbedtls/sha1.h>
#include <mbedtls/sha256.h>
#include <mbedtls/md5.h>
#include <mbedtls/aes.h>

WebServer server(80);

void setup() {
    Serial.begin(115200);
    WiFi.mode(WIFI_AP_STA);
    WiFi.begin("ref", "refref12");
    server.begin();
    HTTPClient http; (void)http;
    esp_now_init();
    BLEDevice::init("ref");
    BLEServer *s = BLEDevice::createServer(); (void)s;
    mbedtls_sha1_context c1;   mbedtls_sha1_init(&c1);
    mbedtls_sha256_context c2; mbedtls_sha256_init(&c2);
    mbedtls_md5_context c3;    mbedtls_md5_init(&c3);
    mbedtls_aes_context c4;    mbedtls_aes_init(&c4);
}

void loop() {}
INO
fi

echo "[*] Compiling for $BOARD (pulls in the SDK; a few minutes the first time)"
arduino-cli compile -b "$BOARD" --output-dir "$OUT/build" "$OUT/ref"

ELF="$(ls "$OUT/build"/*.elf 2>/dev/null | head -1 || true)"
if [ -z "$ELF" ]; then
    echo "[x] No ELF produced - check the compile output above."
    echo "    If the 'full' profile failed to compile on this core version, retry with 'minimal'."
    exit 1
fi
cp "$ELF" "$OUT/reference.elf"

# The core also ships prebuilt, symbol-bearing static libs; point Ghidra at
# these too for extra coverage beyond what the sketch links. The layout differs
# by core line: 2.0.x uses tools/sdk/<chip>/lib, 3.0.x uses esp32-arduino-libs.
LIBDIR="$(find "$ARDUINO_DIRECTORIES_DATA" -type d \
    \( -path "*esp32-arduino-libs*/${CHIP}/lib" -o -path "*/hardware/esp32/*/tools/sdk/${CHIP}/lib" \) \
    2>/dev/null | head -1 || true)"

# --- Deterministic IDF check ------------------------------------------------
# The installed core records its exact ESP-IDF in platform.txt as
# IDF_VER="v4.4.7-dirty" (true for both 2.0.x and 3.0.x). Compare that full
# patch-level version to the badge's own IDF (from the analysis metadata) so you
# KNOW whether this core matches before spending time in Ghidra - no version
# table to trust. Every extraction is `|| true` so a miss never aborts the run.
ver3() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }

CORE_IDF=""
CORE_PLATFORM="$ARDUINO_DIRECTORIES_DATA/packages/esp32/hardware/esp32/$VER/platform.txt"
if [ -f "$CORE_PLATFORM" ]; then
    CORE_IDF="$(ver3 "$(grep -oE 'IDF_VER="[^"]+"' "$CORE_PLATFORM" 2>/dev/null | head -1 || true)")"
fi

BADGE_IDF=""
if [ -f "$WORK/meta/parts_manifest.json" ]; then
    BADGE_IDF="$(ver3 "$(grep -oE 'idf=v?[0-9]+\.[0-9]+\.[0-9]+' "$WORK/meta/parts_manifest.json" 2>/dev/null | head -1 || true)")"
fi
if [ -z "$BADGE_IDF" ] && [ -f "$WORK/reports/triage.txt" ]; then
    BADGE_IDF="$(ver3 "$(grep -oE 'esp-idf: v[0-9]+\.[0-9]+\.[0-9]+' "$WORK/reports/triage.txt" 2>/dev/null | head -1 || true)")"
fi

IDF_MATCH="unknown"
if [ -n "$BADGE_IDF" ] && [ -n "$CORE_IDF" ]; then
    if [ "$BADGE_IDF" = "$CORE_IDF" ]; then IDF_MATCH="yes"; else IDF_MATCH="no"; fi
fi

# Copy the precompiled static libs into the workspace. reference.elf only holds
# the SDK functions the sketch linked (hundreds); these .a archives hold the
# WHOLE SDK (thousands) with symbols - and they're the exact binaries this core
# ships, so FID/BinDiff against them is what actually names most of the dump.
# The ghidra container can't reach the arduino container's filesystem, so they
# have to live in the shared workspace.
LIB_COUNT=0
LIB_OUT=""
if [ -n "$LIBDIR" ]; then
    LIB_OUT="$OUT/lib"
    mkdir -p "$LIB_OUT"
    cp "$LIBDIR"/*.a "$LIB_OUT/" 2>/dev/null || true
    LIB_COUNT="$(find "$LIB_OUT" -name '*.a' 2>/dev/null | wc -l | tr -d ' ')"
    LIB_MB="$(du -sm "$LIB_OUT" 2>/dev/null | cut -f1 || echo '?')"
fi

{
    echo "core:          arduino-esp32 $VER"
    echo "chip:          $CHIP"
    echo "board:         $BOARD"
    echo "profile:       $PROFILE"
    echo "reference_elf: reference/arduino-esp32-${VER}/reference.elf"
    echo "badge_idf:     ${BADGE_IDF:-unknown}"
    echo "core_idf:      ${CORE_IDF:-unknown}"
    echo "idf_match:     $IDF_MATCH"
    [ "$LIB_COUNT" -gt 0 ] && echo "sdk_libs:      reference/arduino-esp32-${VER}/lib/   ($LIB_COUNT .a archives - import these into Ghidra for full FID coverage)"
} > "$OUT/REFERENCE.txt"

echo
echo "[+] Reference build ready:"
echo "    reference/arduino-esp32-${VER}/reference.elf   (symbolised - a quick FID starter)"
if [ "$LIB_COUNT" -gt 0 ]; then
    echo "    reference/arduino-esp32-${VER}/lib/   ($LIB_COUNT .a archives, ~${LIB_MB} MB)"
    echo "    ^ import THESE for real coverage: reference.elf only has the linked subset."
fi
echo
echo "[*] IDF check:  badge=${BADGE_IDF:-?}   this core (arduino-esp32 $VER)=${CORE_IDF:-?}"
case "$IDF_MATCH" in
    yes) echo "    MATCH - exact IDF ($CORE_IDF). This is the right core; FID against it." ;;
    no)  if [ "${BADGE_IDF%.*}" = "${CORE_IDF%.*}" ]; then
             echo "    NEAR - same IDF line, different patch (badge $BADGE_IDF vs core $CORE_IDF)."
             echo "           Usually still a strong FID match. If it's weak, build a neighbouring"
             echo "           arduino-esp32 patch release, or use BinDiff."
         else
             echo "    MISMATCH - different IDF line. Rebuild on the badge's line and FID that:"
             echo "               IDF v4.4.x -> arduino-esp32 2.0.x ; v5.1.x -> 3.0.x ; v5.3.x -> 3.1.x."
         fi ;;
    *)   echo "    could not compare (missing badge or core IDF) - check reports/triage.txt by hand." ;;
esac
echo
echo "    Apply the symbols to the badge in Ghidra - see docs/name-recovery.md."
echo "    Wrong version? Re-run with another version arg and use BinDiff instead"
echo "    of FunctionID (also in docs/name-recovery.md)."
