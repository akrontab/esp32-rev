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
  container/
    lib/                 format parsers shared by both images
    esptool/             hardware-facing tools
    analysis/            offline analysis tools
docker/
  esptool/               serial acquisition image
  analysis/              offline carving image
  ghidra/                disassembly image (phase 2)
docs/                    architecture, playbook, decisions, troubleshooting
workspace/               per-target artefacts (git-ignored)
requirements.txt         pinned host-side dependencies
```

### Two images, two privilege levels

| Image | Gets the serial device | Purpose |
|---|---|---|
| `esp32-re/esptool` | yes (`--device`) | Anything that talks to the badge |
| `esp32-re/analysis` | **no** | Offline carving and analysis |

The split is deliberate: analysis code can never accidentally reach the
hardware, no matter what it does.

---

## A target workspace

```
workspace/<target>/
  meta/       target.json, efuse_summary.txt, partitions.json, artifacts.sha256
  dumps/      flash_full.bin and any region dumps
  parts/      one .bin per partition, carved from the dump
  extract/    files recovered from SPIFFS / LittleFS / FAT, NVS blobs
  reports/    triage, partitions, nvs-*, hunt, strings
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

| Document | Contents |
|---|---|
| [docs/playbook.md](docs/playbook.md) | The order to actually do things in, with decision points |
| [docs/usb-passthrough.md](docs/usb-passthrough.md) | How the badge reaches a container, and what breaks |
| [docs/architecture.md](docs/architecture.md) | Why it is built this way |
| [docs/decisions.md](docs/decisions.md) | Decision log, including validation evidence |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom-to-fix table |
| [docs/roadmap.md](docs/roadmap.md) | Phase 2: Ghidra, JTAG, wireless |
