# Disassembly with Ghidra

When a flag isn't in strings, NVS, a filesystem, BLE or a crackable hash — i.e.
it's *computed at runtime* — you have to read the code. Ghidra decompiles the
badge's firmware to C.

Ghidra 12.x has **native Xtensa and RISC-V**, so this covers every ESP32:
Xtensa for the classic ESP32 and S2/S3, RISC-V for C3/C6/H2. No third-party
processor module.

Two modes, menu `[33]` and `[34]`.

---

## When it's worth it

Disassembly is the heavy option. Reach for it only after the cheap paths are
exhausted, because on a stripped release build (which most badges are) you get
4000+ functions named `FUN_40xxxxxx` and no symbols — real work to navigate.

It pays off when:
- the challenge validates an answer the badge computes internally (a checksum,
  a custom cipher, a key derivation);
- a string or constant you found needs its *usage* understood;
- you want to confirm what a BLE/WiFi handler actually does with input.

If the flash is encrypted, disassembly of the serial dump is meaningless
(ciphertext) — see the eFuse posture first.

---

## Headless analysis — `[33]`

Runs the whole pipeline unattended and drops the results in the workspace:

1. **`gh-prep`** reads the app image with `espfmt` (the same validated parser
   the analysis pipeline uses) and splits it into its segments, recording each
   one's real load address and whether it's code or data.
2. **`analyzeHeadless`** imports the entry-bearing segment at its true address
   with the right language, and a helper (`AddSegments`) maps the remaining
   segments as memory blocks at *their* addresses. This matters: mapping
   segments correctly is what lets cross-references between code (IROM/IRAM)
   and constants/strings (DROM/DRAM) resolve. The load addresses come from the
   image header — the same ones `reports/triage.txt` prints.
3. Ghidra auto-analyses, then **`ExportArtifacts`** writes plain files:

   | File                                | Contents                             |
   | ----------------------------------- | ------------------------------------ |
   | `reports/ghidra/decompiled.c`       | every function's decompiled C        |
   | `reports/ghidra/functions.txt`      | address, name, size of each function |
   | `reports/ghidra/symbols.txt`        | the symbol table                     |
   | `reports/ghidra/strings-ghidra.txt` | defined strings with addresses       |
   | `reports/ghidra/code-leads.txt`     | ranked shortlist of functions to read (see below) |

Because the output is plain text, you can `grep` the decompilation for a
constant, a string address, or a suspicious operation without opening the GUI.

On the 2025 badge this produced **4,672 decompiled functions** in about a
minute of analysis.

### Automated triage — `code-leads.txt`

4,672 anonymous `FUN_*` functions is too many to read. So the headless run
finishes by triaging its own decompilation into a **ranked shortlist**
(`gh-leads.py`, the code-side analogue of `[35]` fw-leads). It writes
`reports/ghidra/code-leads.txt` (and `code-leads.json`) — the functions most
likely to hold a challenge, most-relevant first, each with the reason.

It scores every function on two kinds of signal:

- **Ties back to what the toolkit already found.** If `meta/leads.json` exists
  (from `[35]`), a function that *references* one of those flag tokens,
  credentials, or cracked hashes scores highest — this is what connects a
  static string like `L3tM31n!` to the code that checks it. Run `[35]` before
  the Ghidra pass to light this up.
- **Static heuristics** on each function body: comparison primitives
  (`strcmp`/`memcmp` — an equality check against a secret), XOR/shift-heavy
  code (a custom cipher or checksum), crypto/CRC init constants and the base64
  alphabet, and challenge-flavoured keywords (`unlock`, `access granted`,
  `wrong`, ...). Well-known SDK/libc functions with no other signal are dropped.

Read `code-leads.txt` from the top; each entry gives the address, name, size,
score, and why it was flagged, so you know what to open in the GUI (`[34]`) or
`grep` for in `decompiled.c`. It runs automatically after `[33]` and after
every image of `[36]` (each slot gets its own `code-leads.txt`).

By default the Ghidra project is deleted after export (only the reports are
kept). Pass `--keep` (in the container shell) to retain the `.gpr` for opening
in the GUI later.

---

## Full-dump analysis — `[36]`

`[33]` decompiles **one** app image (normally `parts/app0.bin`, the running
firmware). A full flash dump holds more executable code than that, and `[36]`
reaches all of it:

- the **2nd-stage bootloader** — a separate ESP image at a fixed low offset
  (0x0 on the S3/C-series, 0x1000 on the classic ESP32/S2). This is where
  secure-boot verification, anti-rollback, and any custom pre-boot logic live.
  `[33]` never touches it;
- **every app slot that actually holds firmware** — `factory`, `ota_0`,
  `ota_1`. On an OTA badge these can be *different* firmware versions; comparing
  them is occasionally decisive.

It runs the exact same segment-accurate pipeline as `[33]` — one Ghidra pass
per image — so each image's cross-references resolve the same way.

### What it does

1. **`gh-images.py`** reads the dump and inventories every code-bearing image.
   The bootloader is found at its chip-specific offset; the app slots come from
   the on-flash partition table (both parsed by `espfmt`, the validated parser).
   Blank slots, encrypted partitions, and anything without a valid image header
   are **listed and skipped**, with the reason. The inventory is written to
   `reports/ghidra/images.json`.
2. For each loadable image, it carves that image out of the dump as a
   standalone file and runs `gh-analyze.sh` on it (prep → import at true
   addresses → auto-analyse → export), redirected into a **per-image subdir**.

### Where the output lands

```
reports/ghidra/
  images.json            the inventory: every candidate, offset, and skip reason
  dump-summary.txt        one line per analysed image (function count, path)
  bootloader/            decompiled.c, functions.txt, symbols.txt, strings-ghidra.txt
  app0/                  same four files, for the running app
  ota_1/                 ... one subdir per loadable slot
```

Each subdir has the same four plain-text files as `[33]`, so the same
`grep`-the-decompilation workflow applies — now across the bootloader too.

### On the 2025 badge

The inventory comes out as (ESP32-S3, 8 MB):

| Image        | Offset     | Result                                          |
| ------------ | ---------- | ----------------------------------------------- |
| `bootloader` | `0x000000` | loadable, 3 segments (entry `0x403c98d0`)       |
| `app0`       | `0x010000` | loadable, 5 segments — `arduino-lib-builder`, IDF v4.4.7-dirty |
| `app1`       | `0x340000` | skipped — blank slot (no OTA image flashed)     |

So it adds the bootloader as a new analysis target and correctly leaves the
empty OTA slot alone. If the flash is encrypted, no images will be loadable
(the dump is ciphertext) — check the eFuse posture first, same as `[33]`.

---

## Interactive GUI — `[34]`

Starts Ghidra's full GUI inside the container, served over **noVNC**: open
**http://localhost:6080/vnc.html** in a browser and click Connect. The
workspace is at `/work`.

Use it for the deep dive after headless analysis has pointed you at the
interesting functions — renaming, following cross-references, patching,
scripting. To load the firmware here, import `reports/ghidra/seg_*.bin` at
their addresses, or open the app image and set the language to
`Xtensa:LE:32:default` (or `RISCV:LE:32:default` for C3/C6).

The port is published to `localhost` only, and the container is disposable with
no VNC password — do not expose 6080 on a public interface.

---

## Getting names onto a stripped binary

The single biggest time-saver on an ESP-IDF binary: the app descriptor
(`reports/triage.txt`) tells you the **exact IDF version**. Build a stock
firmware with that same version and diff — the SDK functions match, leaving the
badge's own code as what's left. That turns 4,672 anonymous functions into a
few dozen worth reading. This is a manual step; the toolkit gives you the
version and the decompilation to start from.
