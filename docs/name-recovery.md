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

Applying is interactive, in the GUI (`[34]`). Two matching methods, depending on
how well the version lines up (§3A FunctionID, §3B BinDiff).

### Getting set up in the GUI

0. **Run `[33]` once first.** The segment files you import below
   (`reports/ghidra/seg_*.bin` + `segments.json`) are produced by `[33]`
   (`gh-prep`), *not* by acquire/`[12]` — so a workspace that's only been
   acquired has an empty (or missing) `reports/ghidra/`. `[33]` keeps these files
   after its run, and `[33]` and `[34]` mount the **same** workspace at `/work`,
   so once `[33]` has run they're right there in the GUI. (No `[33]` yet =
   nothing to import.)
1. **Launch `[34]`** and open `http://localhost:6080/vnc.html` → Connect.
   (If `[34]` starts and immediately dies, rebuild the ghidra image first — see
   *Troubleshooting*.)
2. **Load the badge** into the CodeBrowser: import the primary segment
   `reports/ghidra/seg_<n>_<addr>.bin` as **Raw Binary**, language
   `Xtensa:LE:32:default` (or `RISCV:LE:32:default` for C3/C6), base address from
   `reports/ghidra/segments.json`; add the other segments as memory blocks at
   their addresses (**Window → Memory Map**); then **Analysis → Auto Analyze**.
3. **Import the reference**: **File → Import File** → `reference/arduino-esp32-<version>/reference.elf`, and auto-analyze it (it keeps its symbols).

### A. FunctionID — fast, native, best when the version matches

FID hashes each function's instruction bytes (operands/relocations partially
masked), so it tolerates *address* differences but not *codegen* differences.

**Enable the plugin first** (it's not on by default, and the plain Configure
view hides it): in the **CodeBrowser** window — not the project manager —
**File → Configure → the plug / "Configure All Plugins" icon (top-right)**,
filter for **`Fid`**, tick **`FidPlugin`**, OK. A **Function ID** menu then
appears (top level, or under **Tools**). If your build only lists it under an
*Experimental* category, enable it there; if it's genuinely absent, use BinDiff
(§3B) instead.

1. **Function ID → Create new empty FidDb** → e.g. `esp32s3-idf447.fidb`.
2. **Function ID → Populate FidDb from Programs** → pick `reference.elf`
   (and/or ingest the prebuilt `.a` libs named in `REFERENCE.txt`); set a
   library name/version.
3. Open the **badge** program → **Function ID → Choose active FidDbs** → tick
   the new DB, then re-run analysis (**Analysis → One Shot → Function ID**, or a
   full Auto Analyze). Matches get named automatically, and the decompiler
   re-decompiles so the names appear at every call site.

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

## 5. Push the names back into `decompiled.c`

The names are live in the decompiler window, but `reports/ghidra/decompiled.c`
and `code-leads.txt` were written by the earlier headless run and still say
`FUN_*`. To regenerate them with the recovered names: **Window → Script Manager
→ Manage Script Directories → add `/opt/re/bin`**, then run **`ExportArtifacts.java`**
(and `Enrich.java`). A later `grep` / `[35]` / `gh-leads` then reads named code.

## 6. Expectations, and how it fits the rest

- Because of the `-dirty` patches and exact-compiler sensitivity, you won't name
  100%. But even a close build names a **large fraction** of the SDK — enough to
  turn "4,600 unknowns" into "a few dozen worth reading."
- Combine with what you already have: after FID/BinDiff, the functions still
  called `FUN_*` are exactly your **`code-leads.txt`** candidates (`[33]`/`[36]`),
  now with the SDK noise stripped away, and with `Enrich`'s ROM names and
  `func-strings.txt` for context. ROM naming (`rom-syms.py`) covers the mask ROM
  cheaply; this covers the IDF/Arduino layer — together that's most of the
  boilerplate gone.

## Troubleshooting (found the hard way)

- **`[34]` starts, prints "Starting virtual display + VNC", then the container
  dies.** The base image's TigerVNC (>= 1.15) refuses `-SecurityTypes None` on a
  non-local bind. Fixed in `gh-gui.sh` (binds VNC to localhost inside the
  container; noVNC still reaches it). **Rebuild the ghidra image** to pick up the
  fix: menu `[2] → 5`, or `Build-Image -Name ghidra` (fast — only the script
  layer changes, the Ghidra download layer is cached).
- **`[34]` starts then exits ~2 s later even though VNC came up.** Same fix:
  `ghidraRun` is a launcher that forks the JVM and returns, so the container now
  waits on the noVNC bridge, not the launcher. Rebuild as above.
- **No "Function ID" entry in File → Configure.** You're either in the project
  manager window (config is per-tool — use the **CodeBrowser**), or looking at
  the grouped view. Click **"Configure All Plugins"** (plug icon), filter `Fid`,
  enable **`FidPlugin`**. See §3A. No FunctionID module at all → use BinDiff (§3B)
  or rename manually (press **L** on a function).
- **Nothing to import in the GUI — no `seg_*.bin`.** Those come from `[33]`, not
  acquire/`[12]`. If `reports/ghidra/` is empty, run `[33]` once; it writes the
  segments into the shared `/work`, so `[34]` then sees them (see §3 step 0).

See also [ghidra.md](ghidra.md).
