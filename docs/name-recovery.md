# Name recovery — turning `FUN_*` back into names

The single biggest signal-to-noise jump on a stripped badge. A release build
gives Ghidra ~4,600 anonymous `FUN_40xxxxxx` functions, but the large majority
aren't the badge author's code at all — they're **ESP-IDF, the Arduino core,
and libc**, compiled from public source. If you name those, what's *left
unnamed* is the few dozen functions that actually implement the challenges.

The method: rebuild the **same** SDK/toolchain the badge used, but keep the
symbols, then match it against the stripped dump and copy the names across.

## 1. Know what to match

The analysis pipeline already extracted the target from the app descriptor —
see `reports/triage.txt` / `meta/parts_manifest.json`. For the 2025 badge:

- **ESP32-S3**, Arduino core (`project 'arduino-lib-builder'`)
- **ESP-IDF `v4.4.7`** (`idf=v4.4.7-dirty`), built Mar 2024

That maps to the **arduino-esp32 2.0.x** core line (the early-2024 releases,
~**2.0.15 / 2.0.16**, track IDF 4.4.7). The `-dirty` matters: arduino-lib-builder
patches IDF, so it won't be a perfect byte-match — see *Expectations*.

## 2. Build the reference — `[37]`

`[37] Build SDK reference` (image `arduino`, `arduino-ref.sh`) installs the
requested `arduino-esp32` core and compiles a **symbolised** reference ELF for
the badge's chip, into the workspace:

```
reference/arduino-esp32-<version>/
  reference.elf     <- symbolised; feed this to Ghidra
  REFERENCE.txt     <- what was built; path to the prebuilt libs too
```

The default *full* profile references WiFi / HTTP / ESP-NOW / BLE / mbedtls, so
those SDK functions are linked in with symbols (the subsystems a badge actually
uses). It suggests a core version from the detected IDF; press Enter to accept,
or type any version.

## 3. Apply the symbols in Ghidra

Two ways, depending on how well the version lines up. Both are interactive, in
the GUI (`[34]`).

### A. FunctionID — fast, native, best when the version matches

FID hashes each function's instruction bytes (operands/relocations partially
masked), so it tolerates *address* differences but not *codegen* differences.

1. Import & auto-analyze **`reference.elf`** (it keeps its symbols).
2. **Tools → Function ID → Create new empty FidDb** → e.g. `esp32s3-idf447.fidb`.
3. **Function ID → Populate FidDb from Programs** → pick the reference program
   (and/or ingest the prebuilt `.a` libs named in `REFERENCE.txt`); set a
   library name/version.
4. Open the **badge** program (your `parts/app0.bin` project),
   **Function ID → Choose active FidDbs** → tick the new DB, then re-run
   analysis (or the FunctionID analyzer). Matches get named automatically.

### B. BinDiff — fuzzy, best when the version is close but not exact

If you could only find a *newer or older* core than the badge's, FID's exact
hashing will miss a lot; BinDiff's structural matching is far more forgiving and
gives a confidence per function.

1. Install the **BinExport** plugin for Ghidra and the **BinDiff** tool.
2. Export both the **reference** and the **badge** programs to `.BinExport`.
3. Diff them in BinDiff; review matches (sort by confidence) and **port the
   names** from the reference onto the badge for the high-confidence pairs.

## 4. Using a different version (newer or older)

You do **not** need the exact version to benefit. If the badge's version isn't
available, or you want to compare:

- **Re-run `[37]` with another version arg** — the builder builds a matching
  reference for *any* `arduino-esp32` version, new or old. (List versions with
  `arduino-cli core search esp32 --additional-urls <index>` inside the image.)
- **Match as close as you can**, then apply with **BinDiff** (§3B) rather than
  FunctionID — a one-minor-version drift still matches most of the SDK
  structurally. FunctionID is for when you nailed the version.
- Build **several** references (e.g. 2.0.14, 2.0.16, 3.0.x) and keep whichever
  yields the most confident matches; each lands in its own
  `reference/arduino-esp32-<version>/` so they don't collide.

So: the script takes care of the **build** for any version; the **apply** step
(§3) is the same procedure every time — FID for an exact match, BinDiff for a
near one.

## 5. Expectations, and how it fits the rest

- Because of the `-dirty` patches and exact-compiler sensitivity, you won't name
  100%. But even a close build names a **large fraction** of the SDK — enough to
  turn "4,600 unknowns" into "a few dozen worth reading."
- Combine with what you already have: after FID/BinDiff, the functions still
  called `FUN_*` are exactly your **`code-leads.txt`** candidates (`[33]`/`[36]`),
  now with the SDK noise stripped away, and with `Enrich`'s ROM names and
  `func-strings.txt` for context. ROM naming (`rom-syms.py`) covers the mask ROM
  cheaply; this covers the IDF/Arduino layer — together that's most of the
  boilerplate gone.

See also [ghidra.md](ghidra.md).
