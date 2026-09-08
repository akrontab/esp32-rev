# CTF Playbook

The order to work in, and the decisions that change what you do next. Menu
numbers refer to `scripts\badge.ps1`.

---

## Phase 0 — before you touch the badge

1. `[1]` Environment check. Do this **before** the contest, not during it.
   Building images and fixing USB passthrough under time pressure is
   avoidable pain.
2. `[2]` Build both images.
3. Plug the badge in and run `[3]` to confirm it appears and attaches.
   Detach again if you like — the point is to know it works.

Photograph the board first. Note the module marking (ESP32-WROOM-32,
ESP32-S3-WROOM-1, ...), any exposed pads or headers, and the USB bridge chip.
That tells you the architecture before any software runs.

---

## Phase 1 — identify (2 minutes)

`[4]` create a target, `[3]` attach the badge, then `[5]` identify the chip.

You now know the chip family, revision, MAC and flash size. The chip family
decides the CPU architecture, which matters when you get to disassembly:

| Chip | Core | Notes |
|---|---|---|
| ESP32 | Xtensa LX6, dual | The classic module; bootloader at 0x1000 |
| ESP32-S2 | Xtensa LX7 | Native USB |
| ESP32-S3 | Xtensa LX7, dual | Native USB + USB-JTAG |
| ESP32-C3 / C6 / H2 | RISC-V | Bootloader at 0x0; USB-JTAG on-chip |

**Decision point.** If the chip does not respond at all, see
[troubleshooting](troubleshooting.md#the-badge-is-not-detected). If it
responds but reports an unexpected family, trust the tool over the silkscreen.

---

## Phase 2 — security posture (1 minute)

`[6]` Read eFuses. This is the single most important step, because it decides
whether the rest of the playbook is worth running.

**Decision point:**

- **Nothing enabled** → the normal path. Continue to phase 3.
- **Flash encryption enabled** → a serial flash read returns ciphertext.
  Dump it anyway (it is evidence, and some challenges hand you the key later),
  but do not expect strings to appear. Your remaining options are the
  encrypted-flash branch below.
- **Secure boot enabled** → you cannot run modified firmware on this badge.
  Reading is unaffected.
- **Download mode disabled** → serial acquisition is off the table entirely;
  you need JTAG or chip-off.

### The encrypted-flash branch

When flash encryption is on, a plain dump gives high-entropy noise (triage
will say so explicitly). Realistic options, roughly in order of effort:

1. Look for an unencrypted region. Encryption is per-partition-flag; NVS and
   some data partitions are frequently left in the clear. `[12]` will still
   classify each partition, so check the entropy column per partition rather
   than judging the whole dump.
2. Read the console. `[8]` with reset captures the boot log, which is
   plaintext and often names the app, its version and its log tags.
3. If the challenge intends it, the key may be recoverable from elsewhere in
   the CTF — a companion service, a firmware update file, or a leaked eFuse.
4. JTAG (phase 2 tooling) can read decrypted flash **through** the MMU on
   parts where JTAG is not fused off, because the flash controller decrypts
   transparently for the CPU.

---

## Phase 3 — acquire (2–10 minutes)

`[9]` Full acquisition runs identify → eFuses → partition table → full dump
in the right order and hashes everything.

Prefer `[9]` over running the steps individually: it records provenance
consistently, and the partition table is read *before* the long dump so you
learn the layout even if the dump is later interrupted.

While the dump runs, do not unplug the badge. A 4 MB read at 460800 baud takes
roughly 90 seconds; the script falls back to 115200 automatically if the high
rate fails.

**Also capture the boot log** with `[8]` (reset enabled). Two minutes of
console output frequently answers questions that would take an hour of static
analysis — and on badges with an interactive console, it reveals the command
set.

---

## Phase 4 — analyse (offline; unplug the badge)

`[12]` Full analysis pipeline. It runs:

1. **Triage** — entropy map, partition table, every ESP image found with its
   app descriptor.
2. **Split** — one file per partition in `parts/`, each classified by what it
   *actually* contains rather than its declared subtype.
3. **Filesystems** — SPIFFS / LittleFS / FAT extracted into `extract/`,
   including deleted SPIFFS files under `_deleted/`.
4. **NVS** — every key/value pair, including erased-but-readable entries.
5. **Hunt** — flags, credentials, keys, URLs, JWTs, across the raw dump, every
   partition and every extracted file, each hit attributed to its source.

Read `reports/hunt.txt` first, then `reports/triage.txt`.

### Where flags actually hide, in rough order of likelihood

1. **NVS** — `reports/nvs-*.txt`. Check erased entries too.
2. **A filesystem partition** — `extract/`. Web assets, config JSON, text.
3. **Plain strings in the app image** — `reports/strings.txt`.
4. **Deleted SPIFFS files** — `extract/<part>/_deleted/`.
5. **Assembled at runtime** — nothing in strings; needs disassembly, or watch
   the console while driving the badge's own UI.
6. **A region no partition claims** — the hunt searches raw flash too, which
   is why leads sometimes cite `dumps/flash_full.bin` and nothing else.

---

## Phase 5 — go deeper

When the easy paths are exhausted:

- **Custom patterns.** Drop a `patterns.txt` into the target workspace (one
  ripgrep regex per line) and re-run `[17]`. Use this the moment you learn the
  challenge's flag format. Your patterns are searched *in addition* to the
  built-in ones, so you never lose the credential and key patterns by adding
  your own; `#!replace` in the file switches the defaults off when you want a
  narrow search.
- **Lower the string threshold.** `MINLEN=4` finds short tokens the default
  misses.
- **Read the boot log again**, this time driving the badge's UI, buttons or
  radio while capturing.
- **Disassemble.** This is where the Ghidra image (phase 2) comes in — load
  the app partition at its DROM/IROM load addresses from `reports/triage.txt`.
  The segment load addresses printed there are exactly what Ghidra needs.

---

## Keeping notes

Each target gets a `NOTES.md` from the findings template. Fill it in as you
go: in a timed contest the thing you lose to is re-deriving a fact you already
found two hours ago.

`[20]` gives a cross-target summary — chip, dump status, partition count,
extracted files, NVS keys and flag-shaped leads per badge.
