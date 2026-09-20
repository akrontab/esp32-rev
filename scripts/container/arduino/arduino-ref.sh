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
# these too for extra coverage beyond what the sketch links.
LIBDIR="$(find "$ARDUINO_DIRECTORIES_DATA" -type d -path "*esp32-arduino-libs*/${CHIP}" 2>/dev/null | head -1 || true)"

# --- Deterministic IDF check ------------------------------------------------
# arduino-esp32 pins one ESP-IDF per release, and the prebuilt-libs path encodes
# it (idf-release_v4.4_<date>). Compare that (major.minor) to the badge's own IDF
# (from the analysis metadata) so you KNOW this core's IDF line matches before
# spending time in Ghidra - no version table to trust, just the two values.
maj_min() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+' | head -1; }

CORE_IDF="$(maj_min "$(printf '%s' "$LIBDIR" | grep -oE 'v[0-9]+\.[0-9]+' | head -1)")"

BADGE_IDF=""
if [ -f "$WORK/meta/parts_manifest.json" ]; then
    BADGE_IDF="$(maj_min "$(grep -oE 'idf=v?[0-9]+\.[0-9]+' "$WORK/meta/parts_manifest.json" | head -1)")"
fi
if [ -z "$BADGE_IDF" ] && [ -f "$WORK/reports/triage.txt" ]; then
    BADGE_IDF="$(maj_min "$(grep -oE 'esp-idf: v[0-9]+\.[0-9]+' "$WORK/reports/triage.txt" | head -1)")"
fi

IDF_MATCH="unknown"
if [ -n "$BADGE_IDF" ] && [ -n "$CORE_IDF" ]; then
    if [ "$BADGE_IDF" = "$CORE_IDF" ]; then IDF_MATCH="yes"; else IDF_MATCH="no"; fi
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
    [ -n "$LIBDIR" ] && echo "prebuilt_libs: $LIBDIR   (path inside the arduino container)"
} > "$OUT/REFERENCE.txt"

echo
echo "[+] Reference build ready:"
echo "    reference/arduino-esp32-${VER}/reference.elf   (symbolised - feed to Ghidra FunctionID)"
[ -n "$LIBDIR" ] && echo "    prebuilt libs (in container): $LIBDIR"
echo
echo "[*] IDF check:  badge=${BADGE_IDF:-?}   this core (arduino-esp32 $VER)=${CORE_IDF:-?}"
case "$IDF_MATCH" in
    yes) echo "    MATCH - this core's IDF line matches the badge. Good version to FID against." ;;
    no)  echo "    MISMATCH - rebuild with a core on the badge's IDF line and FID that instead:"
         echo "               IDF v4.4.x -> arduino-esp32 2.0.x ;  IDF v5.1.x -> 3.0.x ;  v5.3.x -> 3.1.x." ;;
    *)   echo "    could not compare (missing badge IDF or libs path) - check reports/triage.txt by hand." ;;
esac
echo
echo "    Apply the symbols to the badge in Ghidra - see docs/name-recovery.md."
echo "    Wrong version? Re-run with another version arg and use BinDiff instead"
echo "    of FunctionID (also in docs/name-recovery.md)."
