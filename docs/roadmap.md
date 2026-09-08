# Roadmap

Phase 1 (built): serial acquisition and offline static analysis.

The items below are deliberately deferred, not forgotten. Each notes what
would trigger building it.

---

## Ghidra image — disassembly

**Build it when:** the flag is not in strings, NVS or a filesystem, i.e. it is
computed at runtime.

**Decided design** (recorded when the project was scoped):

- Headless `analyzeHeadless` for repeatable per-dump analysis, so every new
  dump gets disassembly, decompilation and symbol/string reports as files
  without interaction.
- Plus an optional GUI served over noVNC, opened in a browser at
  `localhost:6080`, for real interactive exploration.
- One image, ~2–3 GB.

**Notes for the implementation:**

- Ghidra has native Xtensa support in recent versions, covering ESP32/S2/S3;
  RISC-V covers C3/C6/H2.
- Load the app partition (`parts/factory.bin` or `parts/ota_0.bin`), not the
  whole flash dump.
- The segment load addresses needed for correct memory mapping are already
  printed by `[13]` triage — `seg0 load=0x3f400020` style lines. Map DROM and
  IROM segments at those addresses or cross-references will be meaningless.
- The app descriptor gives the exact IDF version, which lets you diff against
  a stock build of the same version to separate badge code from SDK code —
  usually the single biggest time saver on an ESP32 binary.

---

## JTAG / OpenOCD image — live debugging

**Build it when:** flash is encrypted, or you need runtime state.

- `openocd-esp32` plus the Xtensa / RISC-V GDB.
- Requires exposed JTAG pads, or a native USB-JTAG part (S3/C3/C6) where the
  interface is on-chip — check `[6]` first, since JTAG can be fused off.
- The high-value capability is reading flash *through* the CPU on an encrypted
  device: the flash controller decrypts transparently for the core, so a JTAG
  read of the mapped region gives plaintext where a serial dump gives
  ciphertext.
- USB passthrough works the same way as for serial; a native USB-JTAG part
  presents an additional interface on the same device.

---

## BLE — done (host-side)

BLE GATT enumeration against the badge's own services is **built** and
validated on the 2025 badge. It runs host-side in the venv via `bleak`, not in
a container, because Bluetooth cannot be containerised on Docker Desktop/WSL2.
See [ble.md](ble.md) and decision [D13](decisions.md#d13--ble-tooling-runs-host-side-not-in-a-container).

Menu `[25]`/`[26]`/`[27]`: scan, dump GATT + read all characteristics,
subscribe to notifications / write.

## Wireless — still open

**Build it when:** a challenge needs more than reading the badge's own GATT.

- **BLE sniffing** — capturing traffic *between* the badge and another device
  (e.g. watching a pairing or a notification exchange) needs dedicated
  hardware: an nRF52840 dongle running Sniffle, or a TI CC26x2. This is
  separate from acting as a central, which is already done.
- **WiFi** — if a badge exposes a SoftAP or a network service, scanning and
  talking to it is a normal-networking job and does not need the radio-level
  tooling above.

---

## Smaller ideas

- **Firmware diffing** — dump, interact with the badge, dump again, diff. The
  hashing ledger already makes this trivial to reason about; it just needs a
  menu item and a report.
- **Coredump parsing** — the `coredump` partition is already carved and
  classified; parsing it would give a register and stack snapshot from the
  last crash.
- **OTA slot comparison** — badges with `ota_0`/`ota_1` often have two
  different firmware versions on them. Comparing app descriptors across slots
  is cheap and occasionally decisive.
- **Chip-off / SPI flash clip** — `flashrom` in a container with a CH341A
  programmer, for a badge whose download mode is fused off.
