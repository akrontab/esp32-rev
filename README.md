# ESP32 Badge Reverse-Engineering Toolkit

Containerised tooling for reverse-engineering an ESP32 conference badge with
no source code, driven from a single menu.

Everything runs in Docker. The only thing installed on the host is
[usbipd-win](https://github.com/dorssel/usbipd-win) — without it a Linux
container cannot see a Windows COM port at all — plus a project-local
`.venv/` for host-side helper scripts.

**Every operation in this toolkit is read-only with respect to the badge.**
Nothing writes flash, erases, or burns eFuses. See [Safety](#safety).

---

## Quick start

```powershell
# 1. Launch the control plane (creates and activates .venv on first run)
.\scripts\badge.ps1

# 2. From the menu:
#    [1] Environment check     - confirms Docker, usbipd, USB passthrough
#    [2] Build images          - choose "both" (~570 MB total, a few minutes)
#    [4] Select/create target  - name your badge
#    [3] USB device manager    - plug the badge in, then attach it
#    [9] Full acquisition      - identify, eFuses, partitions, full dump
#    [12] Full analysis        - carve, extract, dump NVS, hunt for flags
```

You can also jump straight to a target:

```powershell
.\scripts\badge.ps1 -Target defcon-badge
```

---

## How the badge reaches a container

Windows cannot hand a COM port to a Linux container. The route used here is
USB/IP into the VM that Docker Desktop already runs its containers in:

```
badge (USB-serial bridge)
   |  usbipd bind          one-off, needs Administrator (UAC prompt)
   |  usbipd attach --wsl docker-desktop
   v
/dev/ttyUSB0  inside the Docker Desktop WSL2 VM
   |  docker run --device=/dev/ttyUSB0
   v
esp32-re/esptool container
```

Attaching to the `docker-desktop` distro specifically is what makes the device
node visible to containers — attaching to a user distro such as Ubuntu would
not. Details and failure modes: [docs/usb-passthrough.md](docs/usb-passthrough.md).

---

## Layout

```
scripts/
  badge.ps1              control plane - the only thing you run directly
  lib/                   PowerShell modules (state, docker, usbipd, venv)
  host/                  host-side Python helpers, run inside .venv
    ble/                 BLE central (bleak, Windows stack)
    wifi/                WiFi scan (Windows WLAN service)
  container/
    lib/                 format parsers shared by the images
    esptool/             hardware-facing tools
    analysis/            offline analysis tools (incl. fw-wifi)
    hashcat/             local GPU hash cracking
docker/
  esptool/               serial acquisition image
  analysis/              offline carving image
  hashcat/               local GPU cracking image (CUDA)
  ghidra/                disassembly image (Xtensa + RISC-V)
linode/                  Terraform for the escalation cracking rig
wordlists/               big wordlists (git-ignored; fetch on demand)
docs/                    architecture, playbook, decisions, troubleshooting, ...
workspace/               per-target artefacts (git-ignored)
requirements.txt         pinned host-side deps (rich, pyserial, bleak)
```

### Where things run, and why

Three container images at two privilege levels, plus two host-side capabilities
that **cannot** be containerised on Docker Desktop/WSL2 and so run in the venv
against the Windows stack directly:

| Capability          | Runs in       | Gets the hardware?                                               |
| ------------------- | ------------- | ---------------------------------------------------------------- |
| `esp32-re/esptool`  | container     | yes (`--device` serial) — the only thing that talks to the badge |
| `esp32-re/analysis` | container     | **no** — offline carving/analysis, incl. WiFi capability recon   |
| `esp32-re/hashcat`  | container     | GPU (`--gpus all`) — local hash cracking                         |
| BLE (scan/GATT)     | **host venv** | Windows Bluetooth stack — [containers can't do BLE](docs/ble.md) |
| WiFi scan           | **host venv** | Windows WLAN service — same reason                               |

The container split is deliberate: analysis and cracking code can never reach
the serial hardware. BLE and WiFi are host-side because AF_BLUETOOTH and
wireless adapters aren't available inside Docker Desktop containers at all.

---

## A target workspace

```
workspace/<target>/
  meta/       target.json, efuse_summary.txt, partitions.json, artifacts.sha256
  dumps/      flash_full.bin and any region dumps
  parts/      one .bin per partition, carved from the dump
  extract/    recovered files: SPIFFS/LittleFS/FAT, NVS blobs, ble/ characteristics
  reports/    triage, partitions, nvs-*, hunt, strings, ble-scan, ble-gatt
  logs/       serial captures and actions.jsonl (every action, timestamped)
  NOTES.md    your findings
```

Every artefact is SHA-256 hashed into `meta/artifacts.sha256` as it is
produced, and every action appends a JSON line to `logs/actions.jsonl`. Menu
option 19 re-verifies the hashes — worth doing before you trust a dump.

---

## What the analysis actually understands

The ESP-specific formats are parsed by code in `scripts/container/lib/`, so
analysis needs no network and no ESP-IDF install:

- **`espfmt.py`** — application/bootloader image headers, segments, checksum
  and SHA-256 validation, the app descriptor (project name, version, IDF
  version, build date, anti-rollback counter), and the partition table.
- **`nvsfmt.py`** — NVS key/value store, including **erased-but-still-readable
  entries**, which is where stale credentials survive.
- **`spiffsfmt.py`** — SPIFFS, by sweeping every page rather than trusting the
  filesystem's own bookkeeping, so damaged images still yield files.
  Deleted files are recovered into `extract/<part>/_deleted/`.
- LittleFS via `littlefs-python`, FAT via `7z`.

All three parsers were validated against ground truth produced by Espressif's
own tools — see [docs/decisions.md](docs/decisions.md#validation).

---

## Flag hunting and patterns

**Read this before the contest.** The hunt (`[17]`, and stage 5 of `[12]`) is
what turns a 4 MB dump into a short list of leads. Its default patterns are a
*starting point* — the moment you learn the event's actual flag format, tell
the hunt about it or you will scroll past your own answer.

### What it searches

`reports/strings.txt` — every string from the raw dump, every carved
partition, and every extracted file, in both 8-bit and UTF-16, each line
prefixed with the file it came from. Hits are therefore always attributable:

```
194:extract/storage/flag.txt: CTF{spiffs_flag_here}
```

Results land in `reports/hunt.txt`, with a **highest-value leads** section at
the bottom that pulls out flag-shaped strings. Read that first.

### Adding the event's flag format

Create `workspace/<target>/patterns.txt`, one regex per line, then re-run
`[17]`. No rebuild needed — the file is read from the mounted workspace.
Blank lines and `#` comments are ignored.

```
# workspace/defcon-badge/patterns.txt
DC32\{[^}]{0,120}\}
sk_live_[A-Za-z0-9]{16,}
```

**Your patterns are added to the built-in ones, not swapped for them.** You
keep the credential, key and JWT patterns for free, and your own are searched
first and tagged `[custom]` in the report:

```
patterns: 2 custom + 12 default (mode: append)

### [custom] /DC32\{[^}]{0,120}\}/
### [default] /-----BEGIN [A-Z ]*PRIVATE KEY-----/
```

A default that your file already states verbatim is dropped, so copying lines
out of the built-in list never gives you duplicate sections.

### Narrowing to just your patterns

When you know exactly what you are looking for and the generic patterns are
only noise, put `#!replace` on a line of `patterns.txt` to switch the defaults
off:

```
#!replace
DC32\{[^}]{0,120}\}
```

The hunt then reports `defaults DISABLED (#!replace)` so the narrower search
is never a silent surprise.

To change the built-in list permanently, edit `DEFAULT_PATTERNS` at the top of
`scripts/container/analysis/fw-hunt.sh` and rebuild the analysis image (`[2]`).

### Regex flavour — the gotcha

Patterns are **ripgrep (Rust regex)**, not PCRE. Rust rejects pointless
escapes rather than ignoring them: `\"` is a hard error, not a quoted `"`.
Put quote characters into a class bare — `["':= ]`.

This bit during development, and it failed *silently* — the affected patterns
reported "no matches" rather than an error. The hunt now separates ripgrep's
exit 1 (genuinely no match) from exit 2 (bad pattern) and prints:

```
### /(ssid|wifi)[\"':= ]{1,4}.../
  [!] INVALID PATTERN - not searched:
      regex parse error: unrecognized escape sequence
```

If you ever see that, the pattern was **skipped entirely** — fix it and re-run.
No other lookaround/backreference constructs are available either; Rust regex
has no `(?=...)` or `\1`.

### What the defaults cover

Flag braces (`flag{}`, `FLAG{}`, `CTF{}`, plus a generic `WORD{...}`), PEM
private keys and certificates, credential-ish assignments
(`password`/`token`/`api_key`/`secret`/`auth`), WiFi `ssid`/`psk`, URLs, long
base64 blobs, JWTs, MAC addresses, and 32–64 char hex (hashes and keys).

### When the hunt comes back empty

1. **Lower the string threshold.** The default is 6 characters, which misses
   short tokens. From the analysis shell (`[22]`):
   ```bash
   MINLEN=4 fw-hunt.sh
   ```
2. **Check `reports/strings.txt` by hand.** The pattern list is not a
   substitute for reading; a flag stored without a recognisable wrapper will
   never match a generic pattern.
3. **Look at NVS separately** (`reports/nvs-*.txt`), including the
   erased-but-readable entries — those are stale values still on flash.
4. **Consider that it is assembled at runtime.** If nothing is stored as a
   plain string, no pattern will find it; that is the point at which
   disassembly (`[33]`/`[34]`, [docs/ghidra.md](docs/ghidra.md)) or driving the
   badge's own UI while capturing the console (`[8]`) becomes the cheaper path.

---

## Safety

- No menu item writes to the badge. There is no write-flash, erase-flash or
  eFuse-burn path in this toolkit at all.
- `espefuse` is only ever invoked with `summary`.
- Reading eFuses **before** dumping is deliberate: if flash encryption is on,
  a serial dump is ciphertext and you want to know that in minute one.
- Filenames recovered from a badge are treated as hostile and cannot escape
  the extraction directory.

## Requirements

- Windows 11 with Docker Desktop (WSL2 backend)
- `usbipd-win` — `winget install usbipd`
- Python 3.8+ on the host (only for the optional host helpers)
- ~5 GB free disk for images and dumps

## Documentation

| Document                                           | Contents                                                                                 |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| [docs/background.md](docs/background.md)           | **New to ESP32 RE? Start here.** How to read a dump: eFuses, partitions, app images, NVS |
| [docs/hash-cracking.md](docs/hash-cracking.md)     | Cracking hashes: local GPU first, Linode rig as manual escalation                        |
| [docs/ble.md](docs/ble.md)                         | Bluetooth LE challenges: scan, dump GATT, why BLE runs host-side                         |
| [docs/wifi.md](docs/wifi.md)                       | WiFi capability recon: firmware analysis + host SoftAP scan                              |
| [docs/ghidra.md](docs/ghidra.md)                   | Disassembly: headless decompilation + noVNC GUI (Xtensa/RISC-V)                          |
| [docs/playbook.md](docs/playbook.md)               | The order to actually do things in, with decision points                                 |
| [docs/usb-passthrough.md](docs/usb-passthrough.md) | How the badge reaches a container, and what breaks                                       |
| [docs/architecture.md](docs/architecture.md)       | Why it is built this way                                                                 |
| [docs/decisions.md](docs/decisions.md)             | Decision log, including validation evidence                                              |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom-to-fix table                                                                     |
| [docs/roadmap.md](docs/roadmap.md)                 | What's built vs. deferred: Ghidra, JTAG, WiFi attacks                                    |
