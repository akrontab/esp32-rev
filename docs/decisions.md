# Decision log

Why the project is shaped the way it is. Newest decisions at the bottom.
Update this when a decision changes, rather than silently changing behaviour.

---

## D1 — All tooling runs in containers

**Decision.** No RE tooling is installed on the host. Two images:
`esp32-re/esptool` and `esp32-re/analysis`.

**Why.** A stated project constraint. It also means the toolchain is
reproducible and disposable: a mid-contest "did I break my environment?"
question is answered by rebuilding an image.

**Exception.** `usbipd-win` (see D2) and a project-local `.venv` (D8).

---

## D2 — USB reaches containers via usbipd into the `docker-desktop` distro

**Decision.** `usbipd bind` + `usbipd attach --wsl docker-desktop`, then
`docker run --device`.

**Why.** Windows cannot pass a COM port to a Linux container. Attaching to
the distro Docker runs containers in puts the device node in the same kernel
the container uses. Attaching to a user distro such as Ubuntu would create the
node somewhere containers cannot see it.

**Verified before building anything:** `vhci-hcd` loads in the Docker VM
(kernel 6.6.87.2), and `cp210x`, `ch341`, `ftdi_sio`, `pl2303` and `cdc-acm`
are all present, so common badge bridges enumerate without a custom kernel.

---

## D3 — The control plane is PowerShell

**Decision.** `scripts/badge.ps1`, with tool logic in container-side bash.

**Why.** The host-side work is Windows-specific: enumerate USB devices, raise
a UAC prompt for `usbipd bind`, query the WSL VM, translate paths for `-v`
mounts. PowerShell does all of that natively. Git Bash was considered and
rejected: elevation is clumsy, and MSYS path translation actively corrupts
`docker -v` arguments (this bit during development — `C:/...` had to be forced
with `MSYS_NO_PATHCONV=1`).

Tool logic stays in bash inside the containers so it is portable and testable
independently of Windows.

---

## D4 — Two images with different privileges

**Decision.** Only `esp32-re/esptool` is ever given `--device`.
`esp32-re/analysis` gets the workspace and nothing else.

**Why.** Analysis code is the code most likely to be experimental. It should
be structurally incapable of reaching the hardware.

---

## D5 — Read-only toward the badge

**Decision.** No write-flash, erase or eFuse-burn path exists in the toolkit.
`espefuse` is only ever called with `summary`.

**Why.** eFuse burns are irreversible and a bricked badge ends the contest.
The capability can be added deliberately later if a challenge requires it;
its absence should be a conscious choice rather than an oversight.

---

## D6 — ESP formats are parsed by our own code

**Decision.** `espfmt.py`, `nvsfmt.py` and `spiffsfmt.py` implement the image
header, app descriptor, partition table, NVS and SPIFFS formats directly.

**Why.** The alternative is depending on ESP-IDF (a multi-GB install) or on
unmaintained third-party scripts fetched at build time. Parsing the documented
structures keeps the analysis image small, offline and reproducible. It also
lets the parsers be deliberately *tolerant*: a CTF dump is often truncated,
encrypted or mangled, and a parser that returns partial results with a note is
more useful than one that raises.

---

## D7 — Provenance is recorded automatically

**Decision.** Every artefact is SHA-256 hashed into `meta/artifacts.sha256`
when produced; every action appends to `logs/actions.jsonl`.

**Why.** Reproducibility, and catching a truncated read before you waste an
hour analysing it. Menu `[19]` re-verifies.

---

## D8 — A project-local host venv

**Decision.** `scripts/badge.ps1` creates, populates and activates `.venv/` on
startup. Dependencies pinned in `requirements.txt`.

**Why.** Requested. Its scope is host-side helpers only — report generation,
hash verification, serial-port diagnostics — because the containers already
provide isolation for the analysis Python. A project-local venv keeps those
helpers off the system Python, which serves the same goal as D1.

Activation sets `VIRTUAL_ENV` and `PATH` directly rather than dot-sourcing
`Activate.ps1`, which is blocked under a Restricted execution policy. The
effect is identical and needs no policy change.

---

## D9 — Phase 1 scope

**Decision.** Build the serial-acquisition and static-analysis images now.
Ghidra and JTAG are documented but deferred.

**Why.** Chosen scope. Ghidra's preference is recorded for when it is built:
headless analysis for repeatable per-dump runs, plus an optional GUI served
over noVNC in a browser. See [roadmap.md](roadmap.md).

**Update (since):** the initial scope has been extended well past phase 1 —
BLE recon (D13), hash cracking (D14), WiFi recon (D15), and Ghidra itself
(headless + noVNC GUI, [ghidra.md](ghidra.md)) are all built. Only JTAG and
wireless *attack/capture* remain deferred.

---

## D10 — radare2 dropped from the analysis image

**Decision.** No radare2. `binutils-riscv64-linux-gnu` is included instead.

**Why.** radare2 has no installation candidate in Debian bookworm, and
building it from source would bloat the image and its build time. Real
disassembly belongs in the Ghidra image, which handles Xtensa and RISC-V
properly; riscv64 `objdump` covers quick looks at C3/C6 code in the meantime.

---

## D11 — Line endings are pinned in `.gitattributes`

**Decision.** `*.sh`, `*.py` and Dockerfiles are forced to LF; `*.ps1` to CRLF.

**Why.** The container scripts are `COPY`ed into Linux images and executed
there. Git's default Windows behaviour would check them out with CRLF, putting
a `\r` in the shebang, and every script would fail with `bad interpreter` —
an error that gives no hint about its real cause. This was caught by the
warning git printed on the very first `git add`.

---

## D12 — `patterns.txt` extends the built-in hunt patterns

**Decision.** A custom `workspace/<target>/patterns.txt` is **additive**: it is
searched first, then the built-in patterns. `#!replace` on a line of the file
disables the defaults for a deliberately narrow search.

**Why.** The first implementation replaced the defaults, which meant adding
the event's flag format silently dropped the credential, key, JWT and
certificate patterns — exactly when you least want to lose them. That the
README needed a warning block about it was the signal the default was wrong;
the safe behaviour should be the one you get by not thinking about it. Running
a dozen extra regexes over a strings file costs milliseconds.

Defaults duplicated verbatim in the custom file are dropped, so copying lines
out of the built-in list does not produce duplicate report sections. Sections
are tagged `[custom]` / `[default]` so the origin of a hit is never ambiguous.

---

## D13 — BLE tooling runs host-side, not in a container

**Decision.** BLE scan / GATT-dump / notify run in the host venv via `bleak`'s
Windows backend. There is no BLE container.

**Why.** Bluetooth cannot be containerised on Docker Desktop / WSL2, and this
was established empirically, not assumed:

- An Intel adapter passed into the VM with usbipd attaches but yields no `hci`
  interface — the minimal VM has no `/lib/firmware/intel` and Intel radios
  upload firmware at init.
- More fundamentally, `socket(AF_BLUETOOTH, …)` fails with `EAFNOSUPPORT`
  **even `--privileged --net=host`** with `bluetooth.ko` loaded, so
  `bluetoothd` cannot start at all. The WSL2 VM kernel does not expose the
  Bluetooth socket family to containers.

The container image, `bluetoothd` entrypoint and usbipd BT-passthrough code
that were written first are all removed. `bleak` on Windows uses the adapter
the OS already drives — no usbipd, no firmware, no radio passthrough, and it
does not take Bluetooth from Windows. The venv is the sanctioned host-side
exception (see [D8](#d8--a-project-local-host-venv)), so this fits the model
rather than breaking the no-host-tooling rule. Full detail in
[ble.md](ble.md).

**Validated on the real badge:** scan found `BADGE BLE`, and the GATT dump read
its custom-service characteristics live, including the "Crack the Hash"
challenge — through the control-plane menu, into hashed workspace files.

---

## D14 — Hash cracking: local GPU container first, Linode rig by hand

**Decision.** Cracking runs in `esp32-re/hashcat` on the local GPU
(`--gpus all`, `NVIDIA_DRIVER_CAPABILITIES=all`, `-devel-` CUDA base for
`libnvrtc`). The Linode GPU rig is Terraform the **user** applies/destroys, and
only as an escalation when local finds nothing in ~30 min. The control plane
never provisions cloud resources.

**Why.** Fast unsalted hashes of dictionary words crack on the laptop RTX 3060
in seconds (both 2025 badge SHA-1s fell in 27s), so the cloud is wasteful for
the common case and its hourly GPU billing is a foot-gun. Escalation is a
deliberate human decision. rockyou + OneRule are baked into the image for
offline use; big lists stay gitignored like dumps. Full rationale:
[hash-cracking.md](hash-cracking.md).

## D15 — WiFi recon is offline + host-side, and recon-only

**Decision.** WiFi capability analysis runs offline in the analysis container
(`fw-wifi.py`, reads the dump/NVS); the live SoftAP scan runs host-side in the
venv via the Windows WLAN service. No attack tooling.

**Why.** Same containerisation wall as BLE — a Docker Desktop container has no
wireless adapter or WiFi stack, so live scanning must be host-side. Reading
what the firmware *can* do (SoftAP/STA/ESP-NOW/HTTP/SmartConfig) and what it
stores is pure offline analysis of the dump we already have. Deauth/capture/
monitor-mode are attack, need dedicated hardware + Linux, and are deferred
([wifi.md](wifi.md), [roadmap.md](roadmap.md)).

---

## D16 — Full-dump Ghidra analysis reuses the app-image pipeline per image

**Decision.** `[36]` (`gh-dump.sh`) analyses a whole flash dump by
*inventorying* the code images in it (`gh-images.py` → `images.json`), carving
each loadable one out as a standalone image, and running the existing,
validated `[33]` pipeline (`gh-prep` → `analyzeHeadless` → `ExportArtifacts`)
over each — into a per-image subdir (`reports/ghidra/<image>/`). Bootloader is
located at its chip-specific offset; app slots come from the partition table;
blank/encrypted/headerless candidates are listed and skipped, not analysed.

**Why.** The single-image path is already proven on hardware. Rather than
parallel it with a new bulk loader, `[36]` carves each image so the *same*
segment-accurate load runs unchanged — the only new logic is enumeration and
carving, both driven by the already-validated `espfmt` parsers. This adds the
**bootloader** (previously invisible — `[33]` only ever saw `app0`) and every
populated OTA slot as analysis targets, keeping `[33]` byte-for-byte the same
(output redirection is an opt-in `GHIDRA_OUT` env var, unset for `[33]`).

---

## D17 — The interactive console `[24]` is the one write toward the badge

**Decision.** `[24]` (`esp-console.py`) is a two-way serial terminal: it sends
what the operator types to the badge. Every other capability in the toolkit is
strictly read-only toward the badge; this one is the deliberate exception, and
it is labelled as such in the menu ("two-way; sends input") rather than filed
under the read-only HARDWARE header. It runs char-at-a-time in raw mode so
single-key menus and REPLs work and control keys (Ctrl-C/Ctrl-Z) reach the
firmware rather than the host; it exits on Ctrl-] without resetting, and logs
the received stream to `logs/console-*.log`. Keystrokes are not logged verbatim
(they can carry secrets; the badge's own echo already appears in the log).

**Why.** A large class of badge challenges lives behind an interactive serial
menu or a command you must discover and feed — unreachable by capture alone
(`[8]`). Sending console input drives the *running firmware*; it does not write
flash, eFuses, or any persistent state, so it does not compromise the integrity
of the dump the rest of the analysis relies on. That is a meaningfully smaller
step than flashing or fusing, but it is not nothing, so it is called out
explicitly instead of being presented as read-only. It reuses the same
container + `--device` + `-it` path as `[8]`, so a docker-provided pty gives
raw-mode stdin; the default line ending is `\n`, with `cr`/`crlf` offered
because a mismatched EOL is the usual reason a badge appears to ignore input.

---

## D18 — Decompilation triage is a post-export text pass, not an in-Ghidra script

**Decision.** `gh-leads.py` ranks functions *after* the headless run, reading
the emitted `decompiled.c`/`functions.txt` (plus `meta/leads.json`), rather than
walking the program model from inside `analyzeHeadless`. It runs automatically
at the end of `gh-analyze.sh`, so both `[33]` and every image of `[36]` produce
a `code-leads.txt`.

**Why.** An in-Ghidra postScript could use precise cross-references and the call
graph, but it can only be exercised by building the image and running a
multi-minute pass — untestable in isolation, and version-sensitive against the
Ghidra API. The text pass mirrors the established `fw-leads` pattern, runs in a
second, degrades gracefully when an input is missing, and — because Ghidra
already inlines string references into the decompilation — keeps the single
highest-value signal: linking a function to the flag token / credential / hash
the toolkit already found. Its ranking was validated on synthesised
decompilation (a `strcmp`-against-`L3tM31n!` check ranks top; a memcpy wrapper
and an SDK function score zero). A precise xref version remains a possible
upgrade if the heuristics prove too coarse on a real badge.

---

## D19 — Deeper Ghidra signal: runtime-string recovery, ROM naming, xrefs

**Decision.** The lead-hunt is deepened in two layers. In the text pass
(`gh-leads.py`): decode strings the firmware **assembles at runtime** (Ghidra
renders a stack-built string as a wide hex constant — decoded back to ASCII),
extract the **literal a comparison tests against** (the expected password/flag),
and recognise base32 as well as base64. In an in-Ghidra postScript
(`Enrich.java`, run before `ExportArtifacts`): apply **ROM symbol names** from
`rom-syms.py` (parsed from ESP-IDF `.rom.ld`), and emit **string<->function
cross-reference** reports (`xref-strings.txt`, `func-strings.txt`).

**Why.** The highest-value finds on a CTF badge are the strings that never exist
as stored bytes (built on the stack, so invisible to `strings`/`[17]`/`[35]`)
and the exact operand a check compares against — both recoverable from the
decompilation text, and validated on synthesised input. The precise
signals — which function uses a string, and real ROM names — need the program
model, so they live in `Enrich.java`; that also keeps the D18 text-vs-Ghidra
split intact (text pass stays cheap and testable, the API pass adds precision).
ROM naming is the cheap half of de-noising; naming the IDF/Arduino functions
still needs a reference build (FunctionID/FLIRT), noted as the remaining step.

---

## Validation

The format parsers were checked against ground truth from Espressif's own
tooling rather than assumed correct.

| Parser                   | Ground truth                                                | Result                                                                                                   |
| ------------------------ | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `espfmt` image parsing   | A synthesised ESP32 image read back by `esptool image-info` | Entry point, segment table, flash mode/size/freq, checksum, validation hash and app descriptor all agree |
| `espfmt` partition table | Hand-built table with MD5 entry                             | All five partitions and the MD5 recovered                                                                |
| `gh-images` full-dump inventory | The committed 2025 badge dump (`workspace/badge-2025`) | Found bootloader @0x0 (S3) + app0 (`arduino-lib-builder`, IDF v4.4.7-dirty) as loadable; app1 correctly skipped as blank. Carved images re-parse with `checksum_ok`. |
| `gh-leads` decompilation ranking | Synthesised `decompiled.c` + `functions.txt` + `meta/leads.json` | A `strcmp`-vs-`L3tM31n!` check ranks #1 (found-lead + comparison + keywords); crypto-const and XOR-cipher functions follow; memcpy wrapper and an SDK function score zero and are dropped. |
| `gh-leads` runtime-string + operand signals | Synthesised `decompiled.c` | A stack-packed constant `0x656d6b636f6c6e75` decodes to `"unlockme"`; a `strcmp` operand `"L3tM31n!"` is extracted; base32 alphabet flagged. |
| `rom-syms` ld parser | Synthesised `esp32s3.rom.ld` | The three `PROVIDE(name=0xADDR)` lines become address-sorted `addr<TAB>name` rows; a non-`PROVIDE` assignment is ignored. |
| `nvsfmt`                 | Partition built by `esp-idf-nvs-partition-gen` from a CSV   | Namespaces resolved; string, u8, u32, blob-data and blob-index entries all decoded correctly             |
| `spiffsfmt`              | Image built by ESP-IDF's `spiffsgen.py` (v5.2.1)            | All 4 files extracted **byte-identical**, including a 10 KiB multi-page file and a nested path           |

The whole analysis pipeline was then run end-to-end against a composite 4 MB
flash fixture containing a real NVS partition and a real SPIFFS partition at
the offsets its partition table declared. Two defects were found and fixed
this way:

- `strings` was missing from the analysis image, and a `2>/dev/null` was
  hiding the resulting "command not found". The image now installs `binutils`
  and `fw-hunt.sh` checks its tools up front.
- ripgrep rejects `\"` as an unrecognised escape; the affected patterns were
  reporting "no matches" instead of an error. Patterns were corrected and the
  hunt now distinguishes rg's exit 1 (no match) from exit 2 (bad pattern), so
  a malformed custom pattern can never silently look like a clean result.
