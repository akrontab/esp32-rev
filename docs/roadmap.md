# Roadmap

**Built and validated on the 2025 badge:**
- Serial acquisition (chip ID, eFuses, partition table, full flash dump)
- Offline analysis (triage, partition carving, filesystem + NVS extraction,
  flag/secret hunting)
- BLE recon — scan, GATT enumeration, read-all (host-side; [ble.md](ble.md))
- WiFi recon — firmware capabilities + host SoftAP scan ([wifi.md](wifi.md))
- Hash cracking — local GPU first, Linode rig as manual escalation
  ([hash-cracking.md](hash-cracking.md))

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

## Wireless recon — done (host-side)

BLE and WiFi **enumeration** are built and validated on the 2025 badge, both
host-side (Docker Desktop can't give a container the radios):

- BLE `[25]`/`[26]`/`[27]`: scan, dump GATT + read all, notify/write.
- WiFi `[31]`/`[32]`: firmware capabilities + stored config, and a host SoftAP
  scan. See [wifi.md](wifi.md), [ble.md](ble.md), [D13](decisions.md#d13--ble-tooling-runs-host-side-not-in-a-container).

## Wireless attack / capture — still open

**Build it when:** a challenge needs more than reading the badge's own
services — i.e. observing or injecting radio traffic. All of this needs
dedicated hardware and a real Linux host, not a Docker Desktop container:

- **BLE sniffing** — capturing traffic *between* the badge and another device
  (a pairing, a notification exchange): nRF52840 running Sniffle, or a TI
  CC26x2.
- **ESP-NOW capture** — the 2025 badge uses ESP-NOW (badge-to-badge). Reading
  it live needs a second ESP32 in promiscuous mode acting as a capture node — a
  natural companion device rather than a container tool.
- **WiFi monitor mode / deauth / handshake capture** — an adapter that supports
  monitor mode + injection, driven from Linux. Attack, not recon.

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
