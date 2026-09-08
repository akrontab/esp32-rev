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

## Wireless recon

**Build it when:** the challenge is clearly about the badge's radio rather
than its firmware.

- BLE GATT enumeration and WiFi scanning against the badge's own services.
- Needs a Bluetooth adapter passed through with usbipd the same way as the
  serial device, and `bluez` in the container. This machine has an Intel
  adapter at bus `1-14`.
- Note that passing the adapter through takes it away from Windows.

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
