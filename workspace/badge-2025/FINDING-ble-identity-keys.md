# Finding: BLE identity root keys recovered from erased NVS

**Severity:** per-device key compromise (not batch-wide)
**Date:** 2026-09-11
**Source dump:** `dumps/flash_full.bin` (ESP32-S3, flash encryption **disabled**)

## Summary

The badge's BlueDroid `bt_config.conf` is stored **unencrypted** in the NVS
partition. Because flash encryption is off, the BLE **identity root secret (IR)**
and its derived keys (IRK, DHK) are recoverable in cleartext ASCII from a plain
flash dump — including from **erased** NVS entries that were never physically
wiped.

## Recovered keys

From `extract/nvs_blobs/bt_config.conf_bt_cfg_key0_*` (the `_erased` blobs are
stale snapshots; `p00e088_written` is the live copy):

```
LE_LOCAL_KEY_IRK = 9565c30443f0bf288125996763f81734
LE_LOCAL_KEY_IR  = e56cde2d541f274fbee890ce32c386ce
LE_LOCAL_KEY_DHK = fee06670e4886dc33ebe0f7b609c2e77
```

- **IR** (Identity Root) is the master secret; per the BLE spec (Vol 3 Part H)
  `IRK` and `DHK` are AES-derived from it. Holding IR = holding all three.
- **IRK** resolves this device's Resolvable Private Addresses (RPAs).
- **DHK** feeds legacy SMP key generation / signing paths.

## How they were recoverable (erased ≠ wiped)

ESP32 NVS is log-structured. Each 4 KB page has a 32-entry state bitmap; a
"deleted" key just has its 2-bit state flipped to `erased` — **the data bytes
stay in flash** until the whole page is garbage-collected. The toolkit's NVS
parser walks the bitmap and emits `erased` entries alongside `written` ones
(see `state: "erased"` in `meta/nvs.json`). The three erased blobs
(`p00e070 -> p00e074 -> p00e080`) are growing snapshots of the same config as
keys were appended over time — a full version history, not just current state.

## What the keys enable (and what they don't)

| Can do | Cannot do |
|---|---|
| Defeat BLE privacy: compute `ah(IRK, prand)` to confirm a rotating RPA belongs to this badge → **track / de-anonymize it** | Decrypt the encrypted link — that needs the **LTK**, not IRK/DHK |
| Identity-spoof: generate RPAs that resolve to the same IRK, so a central that allowlisted this badge by IRK accepts the clone | Affect any **other** badge (keys are unique — see below) |
| Reconstruct/validate bonding offline when combined with peer `LTK`/`EDIV`/`Rand` from `bt_config.conf` | — |

## Are the keys unique per badge? — Yes (evidence-based)

Standard ESP-IDF generates IR/ER **once on first BLE init** from the hardware
RNG, then persists to NVS. The failure mode that would make keys *shared across
the batch* is a manufacturer flashing one "golden" NVS image onto every unit.

**Test used:** the eFuse MAC is burned per-chip and always unique; NVS caches a
`cal_mac`. If they match, NVS was provisioned *on this chip* (self-generated
keys → unique). If they differ, NVS was cloned from a golden image (shared keys).

| Value | Source | |
|---|---|---|
| `cal_mac = ccba972b1b30` | `meta/nvs.json` (phy namespace) | |
| `MAC (BLOCK1) = cc:ba:97:2b:1b:30` | `meta/efuse_summary.txt` | **match** |

**Conclusion:** MAC-match → NVS was written on this unit → IR/IRK/DHK are
almost certainly **unique to this badge**, not a batch-wide master key. The
compromise is per-device: these keys let you track/spoof *this* badge only.

**Caveat:** strong evidence, not proof. Definitive confirmation requires dumping
a second badge (different eFuse MAC) and checking whether its IRK differs. If two
different badges showed the *same* IRK, that would prove golden-image cloning
despite the MAC match.

## Root cause / vuln framing

The device stores BLE identity secrets in **plaintext NVS with flash encryption
disabled** (see NOTES.md "Security posture"). Anyone with a flash dump — via
plain serial download (no read protection), JTAG (not fused off), or physical
access — extracts the identity root. Erased-but-not-wiped NVS additionally
leaks the *history* of that config.

## Follow-ups

- [ ] Grep `dumps/flash_full.bin` + bt_config blobs for peer `[<mac>]` sections
      carrying `LTK` / `EDIV` / `Rand` — those decrypt traffic from bonded phones.
- [ ] Dump a second WWHF 2025 badge to definitively confirm keys are per-device.
