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

   | File | Contents |
   |---|---|
   | `reports/ghidra/decompiled.c` | every function's decompiled C |
   | `reports/ghidra/functions.txt` | address, name, size of each function |
   | `reports/ghidra/symbols.txt` | the symbol table |
   | `reports/ghidra/strings-ghidra.txt` | defined strings with addresses |

Because the output is plain text, you can `grep` the decompilation for a
constant, a string address, or a suspicious operation without opening the GUI.

On the 2025 badge this produced **4,672 decompiled functions** in about a
minute of analysis.

By default the Ghidra project is deleted after export (only the reports are
kept). Pass `--keep` (in the container shell) to retain the `.gpr` for opening
in the GUI later.

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
