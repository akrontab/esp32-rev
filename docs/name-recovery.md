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
  reference.elf     <- symbolised sketch build; a quick FID starter (linked subset only)
  lib/*.a           <- the core's full precompiled SDK libs; import THESE for real coverage
  REFERENCE.txt     <- what was built, the IDF match verdict, and the lib count
```

The default *full* profile references WiFi / HTTP / ESP-NOW / BLE / mbedtls, so
those SDK functions are linked in with symbols (the subsystems a badge actually
uses). It suggests a core version from the detected IDF; press Enter to accept,
or type any version.

### Which version to target — and how `[37]` confirms it

You don't guess. The toolkit already extracts the two facts that pin the core
version, and `[37]` checks its own answer:

1. **Read them off `reports/triage.txt`** (from `[12]`/`[13]`). The app-descriptor
   line prints the **IDF version** and the **build date**, e.g.:

   ```
   project 'arduino-lib-builder' version 'esp-idf: v4.4.7 38eeba213a' idf v4.4.7-dirty built Mar  5 2024 12:12:53
   ```

   arduino-esp32 pins one IDF per release, so the IDF line + build date place you
   in a release line (IDF **v4.4.x → arduino-esp32 2.0.x**, **v5.1.x → 3.0.x**,
   **v5.3.x → 3.1.x**); the build date breaks ties within a line. `[37]` seeds its
   suggested version from this.

2. **`[37]` then verifies it deterministically** — no version table to trust.
   The installed core records its exact ESP-IDF in `platform.txt`
   (`IDF_VER="v4.4.7-dirty"`), so after building, `[37]` compares that
   **full patch version** against the badge's own IDF and prints one of:

   ```
   [*] IDF check:  badge=4.4.7   this core (arduino-esp32 2.0.16)=4.4.7
       MATCH - exact IDF (4.4.7). This is the right core; FID against it.
   ```

   - **MATCH** — exact IDF; you picked right.
   - **NEAR** — same line, different patch (e.g. badge 4.4.7 vs core 4.4.6):
     usually still a strong FID match; try a neighbouring patch release or BinDiff
     if it's weak.
   - **MISMATCH** — different line (e.g. a 3.0.x core → IDF 5.1): rebuild on the
     badge's line (v4.4.x → 2.0.x, v5.1.x → 3.0.x, v5.3.x → 3.1.x).

   The verdict is also written to `REFERENCE.txt` as `idf_match: yes|no`.

3. So the check now resolves the **exact patch**, not just the line. If it says
   NEAR and the FID result is disappointing, use the **FID match count** (§3A) to
   choose among neighbouring patch releases: build each with `[37]`, apply, keep
   the one that names more.

## 3. Apply the symbols in Ghidra

Applying is interactive, in the GUI (`[34]`). Two matching methods, depending on
how well the version lines up (§3A FunctionID, §3B BinDiff).

### Getting set up in the GUI

0. **Run `[33]` once first, and answer *yes* to "keep the analysed project".**
   That saves a ready Ghidra project into `reports/ghidra/project/` — segments
   mapped, analysis done, ROM names applied — instead of throwing it away. (All
   of this is produced by `[33]`/`gh-prep`, *not* by acquire/`[12]`; `[33]` and
   `[34]` share the `/work` mount, so what `[33]` writes is what `[34]` sees.)
1. **Launch `[34]`** and open `http://localhost:6080/vnc.html` → Connect.
   **If you kept a project, `[34]` opens it automatically** — the badge program
   is already loaded, mapped and analysed, so **skip to step 3**. (If `[34]`
   starts and immediately dies, rebuild the ghidra image first — see
   *Troubleshooting*.)
2. **Only if you did *not* keep a project** — load the badge manually: import the
   primary segment `reports/ghidra/seg_<n>_<addr>.bin` as **Raw Binary**,
   language `Xtensa:LE:32:default` (or `RISCV:LE:32:default` for C3/C6), base
   address from `reports/ghidra/segments.json`; add the other segments as memory
   blocks at their addresses (**Window → Memory Map**); then **Analysis → Auto
   Analyze**.
3. **Import the reference**: **File → Import File**, then navigate to (or type in
   the filename box) **`/work/reference/arduino-esp32-<version>/reference.elf`** —
   the workspace is mounted at `/work`, and the Import dialog opens elsewhere by
   default, so you must go to `/work`. Auto-analyze it after import (it keeps its
   symbols). If `/work/reference/` is empty, `[37]` wasn't run for *this* target,
   or `[34]` is mounting a different target than the one `[37]` built for.

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

0. **Import the SDK libraries — this is what actually gives coverage.**
   `reference.elf` alone only contains the few hundred SDK functions the sketch
   *linked*; your badge uses far more, so ingesting only the ELF leaves most
   functions unnamed. `[37]` copies the core's full precompiled static libs to
   **`/work/reference/arduino-esp32-<version>/lib/`** (dozens of `.a` archives,
   the exact binaries the badge linked against). **Batch-import that `lib/`
   folder** (File → Batch Import, or Import File on the folder), let Ghidra
   auto-analyze the imported programs, and populate the FidDb from *those* (plus
   `reference.elf`). That's thousands of functions to match against instead of
   hundreds.
1. **Function ID → Create new empty FidDb** → e.g. `esp32s3-idf447.fidb`.
2. **Function ID → Populate FidDb from Programs.** This opens a dialog of text
   boxes — fill it (values for the arduino-esp32 2.0.16 / S3 example):

   | Field                   | Value                                                    | Notes                        |
   | ----------------------- | -------------------------------------------------------- | ---------------------------- |
   | **Fid Database**        | your `esp32s3-idf447.fidb`                               | where the hashes are written |
   | **Library Family Name** | `arduino-esp32`                                          | free-text label              |
   | **Library Version**     | `2.0.16`                                                 | free-text label              |
   | **Library Variant**     | `esp32s3` (or `idf4.4.7`)                                | free-text label              |
   | **Base Library**        | *No Base Library*                                        | leave as-is                  |
   | **Root Folder**         | the project folder holding `reference.elf` (usually `/`) | where it reads programs      |
   | **Language**            | `Xtensa:LE:32:default` (`RISCV:...` for C3/C6)           | must match the reference     |
   | **Common Symbols File** | *(blank)*                                                | optional                     |

   Family / Version / Variant are just labels to tell libraries apart later; the
   ones that matter are **Fid Database**, **Root Folder**, and **Language**. The
   `reference.elf` must already be **imported and auto-analyzed** in that Root
   Folder, with a matching language, or nothing is ingested.

   **Where the ingest count shows up:** FID populate runs from the **Ghidra
   Project window** (front end), and reports to the log — a short summary dialog
   at the end, and **Help → Show Log** (`application.log`; search for
   `arduino-esp32` or `Fid`) for the function count. **0 ingested** means the
   Root Folder / Language didn't point at the analyzed reference.

3. Open the **badge** program → **Function ID → Choose active FidDbs** → tick
   the new DB, then re-run analysis (**Analysis → One Shot → Function ID**, or a
   full Auto Analyze). Matches get named automatically, and the decompiler
   re-decompiles so the names appear at every call site.

**Check how much it named.** The count that matters is badge functions renamed,
not functions ingested. Gauge it:
- **Window → Symbol Table**, sort by name — see how many are still `FUN_*` vs
  real names; or
- re-run `ExportArtifacts.java` (§5) and compare `grep -c '^FUN_'
  reports/ghidra/functions.txt` before vs after.

A low match count means the core version is off — build a neighbouring version
with `[37]` and try **BinDiff** (§3B) instead.

### B. BinDiff — fuzzy, best when the version is close but not exact

If FID's exact hashing leaves too much unnamed — a `-dirty` build, or you could
only get a *newer/older* core than the badge's — BinDiff matches functions
*structurally* (call graph + flow shape), so it tolerates codegen differences
and gives a similarity/confidence score per function. It's Google's free
tooling, in two pieces:

- **BinExport** — a Ghidra *extension* that exports a program to a `.BinExport`
  file (and imports diff results back). Runs inside Ghidra.
- **BinDiff** — the standalone differ that compares two `.BinExport` files and
  produces a `.BinDiff` results database.

Both are at <https://github.com/google/bindiff/releases> (BinDiff bundles the
matching BinExport Ghidra extension). **Match the versions to your Ghidra**
(Help → About — this image ships Ghidra **12.1.3**); an extension built for a
different Ghidra major won't load.

#### How the pieces connect here

Ghidra runs **inside the `[34]` container**; BinDiff is a desktop app. So the
export happens in the container, the `.BinExport` files travel through the
shared **`/work`** mount, and you run BinDiff wherever it's installed (your
Windows host is simplest). Everything meets in the workspace.

#### Setup (one time)

1. **Install the BinExport extension into the container Ghidra.** From the
   `[34]` GUI: **File → Install Extensions → `+`**, point it at the BinExport
   zip for Ghidra 12.x (download it on the host and drop it in `/work` so the
   dialog can reach it, or fetch inside the container). Restart Ghidra when
   prompted, then in the CodeBrowser enable it: **File → Configure → Configure
   All Plugins → filter `BinExport` → tick it** (same drill as `FidPlugin`).
2. **Install BinDiff on your host** from the releases page (Windows installer).
   You'll open `.BinExport` files with it.

#### Use

1. **Export both programs to `/work`** (so they land in the workspace). Open the
   **badge** program → **File → Export Program… → format *Binary BinExport*** →
   save to `/work/reports/ghidra/binexport/badge.BinExport`. Do the same for the
   **reference / SDK-libs** program(s) →
   `/work/reports/ghidra/binexport/reference.BinExport`. (Right-click the
   listing also has an *Export* action in some versions.)
2. **Diff them.** On the host, open BinDiff and create a new diff (**File → New
   Diff**) with **primary = the badge**, **secondary = the reference**. The
   files are in `workspace/<target>/reports/ghidra/binexport/`. Or from the CLI:
   `bindiff --primary badge.BinExport --secondary reference.BinExport --output_dir .`
   → produces a `.BinDiff` results file.
3. **Review matches.** In BinDiff's matched-functions view, sort by
   **confidence** (and similarity). High-confidence rows are safe to trust;
   low-confidence ones are guesses — skim before accepting.
4. **Port the names back into Ghidra.** With the BinExport extension installed,
   open the badge program in Ghidra and use its **BinDiff results import** to
   load the `.BinDiff` file and **apply matched names/comments** onto the badge
   (accept high-confidence matches; skip or eyeball the rest). The decompiler
   then shows the ported names, same as FID. (If your version can't import
   results into Ghidra, BinDiff can still write the names — export the matched
   symbols and rename in Ghidra, or work from BinDiff's view.)

#### Tips

- **Primary = badge, secondary = reference** — you're porting names *onto* the
  badge, so it must be the primary.
- Diff against the **SDK `.a` libs** program (from §3A step 0), not just
  `reference.elf` — same coverage argument: more functions to match.
- BinDiff and FID stack: run FID first for the exact-match wins, then BinDiff to
  mop up what FID's hashing missed.
- Re-run `ExportArtifacts.java` (§5) afterwards so `decompiled.c` / `code-leads.txt`
  pick up the ported names.

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
  fix: menu Setup `[1]` → Build images `[2]` → ghidra `[5]` (fast — only the script
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
- **Still lots of `FUN_*` after FunctionID.** Almost always because you ingested
  only `reference.elf` (the linked subset, a few hundred functions). Import the
  **`reference/.../lib/*.a`** archives and populate the FidDb from those too —
  that's the whole SDK (§3A step 0). If the ingest count was in the hundreds,
  this is it. Also: FID skips very small and non-unique functions by design, so
  a residue of `FUN_*` is normal — and if the count is *still* low after the
  libs, the codegen differs enough that **BinDiff** (§3B) will do better than
  FID's exact hashing. Remember the goal isn't 100%: once the SDK noise is named,
  your `code-leads.txt` shortlist is the handful that matter.

See also [ghidra.md](ghidra.md).
