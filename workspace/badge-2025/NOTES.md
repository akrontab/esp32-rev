# WWHF 2025 badge — findings (demo workspace)

Started: 2026-09-08

This is a committed **demo** workspace: a real dump of the Wild West Hackin'
Fest 2025 badge and the reports the toolkit produced from it. Open
`reports/SUMMARY.md` for the one-page brief, or re-run analysis from the dump:
`[R]` RUN ALL (offline) / `[12]` Full analysis on `dumps/flash_full.bin`.

## Hardware

| | |
|---|---|
| Badge / event | Wild West Hackin' Fest (WWHF) 2025 |
| Chip (from `[5]`) | ESP32-S3 (QFN56) |
| Revision | v0.2 |
| MAC | cc:ba:97:2b:1b:30 |
| Flash size | 8 MB (GigaDevice c8:4017) |
| USB bridge | native USB-Serial/JTAG (303a:1001) |

## Security posture (`[6]`)

| | |
|---|---|
| Flash encryption | Disabled |
| Secure boot | Disabled |
| JTAG | enabled (not fused off) |
| Download mode | enabled |
| Read/write protection | none (all eFuse key blocks USER/EMPTY) |

Consequence: fully unlocked — plain serial dump and analysis are meaningful.
See `FINDING-ble-identity-keys.md`: BLE identity root (IR/IRK/DHK) recovered in
cleartext from erased NVS; verified **unique to this badge**, not batch-wide.

## Firmware identity (`[13]`)

| | |
|---|---|
| Project name | arduino-lib-builder |
| ESP-IDF version | v4.4.7 (dirty) |
| Build date | Mar 5 2024 |
| Framework | Arduino core |

## Partition layout (`[7]`)

`app0` in use; `app1`, `spiffs`, `coredump` all **blank** — no OTA was ever
applied. See `reports/partitions.txt` / `reports/SUMMARY.md`.

## Theme & challenges

WarGames / retro-hacking theme (`BHISBIOS (C) 2008`, `FALKEN'S MAZE`,
`GLB THERMONUCLEAR WAR`, the `sshnuke 10.2.2.2` scene). Challenges are delivered
over **BLE GATT** plus embedded string puzzles.

## Leads

| Source | Finding | Followed up? |
|---|---|---|
| BLE GATT | "Crack the Hash": two SHA-1s | Yes — cracked to `accessit` and `darkimage` (menu 30) |
| strings | Caesar cipher `Gwjfp ymj nhj` | → "Break the ice" |
| strings | Bacon cipher `abaab baaaa babba ...` | decode pending |
| strings | `Comment  L3tM31n!` (planted password) | login-puzzle flavor |
| WiFi (`[31]`) | ESP-NOW + HTTP server + SmartConfig, no stored creds | badge-to-badge, not AP-joining |
| NVS (erased) | BLE identity root IR/IRK/DHK in cleartext `bt_config.conf` | Yes — see `FINDING-ble-identity-keys.md` (keys are per-device) |

## Flags

| Challenge | Flag | Where it was |
|---|---|---|
| Crack the Hash | (passwords) accessit / darkimage | BLE characteristics 0x0029 / 0x002d |

## Next steps

- [ ] Finish the Bacon-cipher decode
- [ ] Expect the 2026 badge to be similar (BLE + hash + cipher challenges)
