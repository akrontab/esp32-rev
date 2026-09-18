# Project status / handoff

_Last updated: 2026-09-10. A living "where we are" so any session can resume._

## In one line

A containerised ESP32 badge RE toolkit driven by one PowerShell control plane
(`scripts/badge.ps1`), validated end-to-end on a real 2025 conference badge.
Read-only toward the badge, with one deliberate, labelled exception: the
interactive console `[24]` sends input to drive the running firmware (it never
writes flash/eFuses — see [decisions.md](decisions.md) D17).

## What's built and validated

| Capability | Menu | State |
|---|---|---|
| Setup: quick start, one-key attach | `0`, `a` | done |
| Full run: acquire + analyse → SUMMARY.md | `R` | done |
| Serial acquisition (chip/eFuses/parts/dump) | `5`–`11` | validated on hardware |
| Interactive two-way console (drives badge menus/CLI) | `24` | built (needs hardware to validate) |
| Offline analysis (triage/split/fs/nvs/hunt) | `12`–`17` | validated |
| Strings triage: signal vs noise buckets | `35` | validated (fw-leads) |
| BLE recon (scan / GATT dump / notify) | `25`–`27` | validated (host-side venv) |
| WiFi recon (capabilities / SoftAP scan) | `31`, `32` | validated |
| Hash cracking (local GPU) | `29`, `30` | validated (cracked the badge's SHA-1s) |
| Disassembly (Ghidra headless + GUI) | `33`, `34` | validated (4,672 fns) |
| Full-dump disassembly (bootloader + all app slots) | `36` | validated (inventory on badge dump) |
| Decompilation triage → ranked `code-leads.txt` | auto after `33`/`36` | validated (ranking logic) |
| Workspace: reports / verify / summary | `18`–`20` | done |

Container images: `esp32-re/esptool`, `/analysis`, `/hashcat`, `/ghidra`.
Host-side (venv): BLE + WiFi (can't be containerised on Docker Desktop).

## The reference badge (workspace/badge-2025)

_Committed as a demo workspace_ (dump + reports; the derivable `parts/` and
the ambient WiFi scan are excluded). Clone and open `reports/SUMMARY.md`, or
re-run `[12]` on `dumps/flash_full.bin` to regenerate everything.


- **ESP32-S3** (QFN56, rev v0.2), **8 MB** flash, MAC cc:ba:97:2b:1b:30.
- **Unlocked**: no secure boot, no flash encryption, JTAG on. Plain dump works.
- Arduino core on **ESP-IDF v4.4.7**, built Mar 2024.
- Layout: `app0` used; `app1`, `spiffs`, `coredump` all **blank** (no OTA applied).
- **WarGames / retro-hacking theme.** Challenges delivered over **BLE GATT**
  ("Crack the Hash" → SHA-1s cracked to `accessit` / `darkimage`) plus embedded
  string puzzles (Caesar `Gwjfp ymj nhj`, a Bacon cipher, base64/base32, the
  `sshnuke 10.2.2.2` scene, `L3tM31n!`).
- Uses **ESP-NOW + HTTP server + SmartConfig**; no stored WiFi creds → it's
  badge-to-badge, not AP-joining.

Expectation: the 2026 badge is similar (BLE + hash + cipher challenges).

## Outstanding / not yet done

- **Linode cracking rig: validated to `terraform plan` only, never `apply`ed.**
  Config is clean against the live API (token/region `us-ord`/plan
  `g2-gpu-rtx4000a1-s` all accepted). First `apply` is a paid shakeout — watch
  cloud-init's NVIDIA driver step. Lock `allowed_ssh_cidr` to your IP first.
  See [hash-cracking.md](hash-cracking.md), [../linode/README.md](../linode/README.md).
- **Deferred (need dedicated hardware / real Linux):** JTAG/OpenOCD; wireless
  *attack/capture* — BLE sniffing, ESP-NOW capture, WiFi monitor mode. See
  [roadmap.md](roadmap.md).
- **Ghidra on a stripped binary** yields `FUN_*` names; diffing against a stock
  IDF v4.4.7 build to recover names is a manual step (noted in [ghidra.md](ghidra.md)).

## The normal flow

```
.\scripts\badge.ps1
  [0] Quick start   (first run: build images, target, attach)
  [R] RUN ALL       (acquire from badge + analyse -> reports/SUMMARY.md)
  read reports/SUMMARY.md, then reports/leads.txt
  BLE: [25] scan -> [26] dump GATT ; hashes: [29] id -> [30] crack
```

## Environment notes (this machine)

- Docker Desktop (WSL2), GPU passthrough works (`--gpus all`), RTX 3060 6 GB.
- usbipd-win 5.3.0; badge is native-USB (`303a:1001`) → shows as `/dev/ttyACM*`
  and **re-enumerates** on reset — the control plane auto-resolves to the
  newest node (a stale node once caused a chip-ID hang; fixed).
- Terraform installed; Linode token goes in `linode/terraform.tfvars` (gitignored).

## Conventions when resuming

- After any menu edit, re-run the AST audit (parse + dispatch→definition check)
  — a missing function only fails at runtime, which is how a deleted
  `Invoke-BleScan` slipped through once.
- Verify format/tool changes against ground truth or the real badge dump.
- Decisions are logged in [decisions.md](decisions.md) (D1–D15).
