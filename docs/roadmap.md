# Roadmap

**Built and validated on the 2025 badge:**
- Serial acquisition (chip ID, eFuses, partition table, full flash dump)
- Offline analysis (triage, partition carving, filesystem + NVS extraction,
  flag/secret hunting)
- BLE recon — scan, GATT enumeration, read-all (host-side; [ble.md](ble.md))
- WiFi recon — firmware capabilities + host SoftAP scan ([wifi.md](wifi.md))
- Hash cracking — local GPU first, Linode rig as manual escalation
  ([hash-cracking.md](hash-cracking.md))
- Disassembly — Ghidra headless (Xtensa + RISC-V) with segment-accurate
  loading, plus a noVNC GUI ([ghidra.md](ghidra.md)). 4,672 functions
  decompiled from the 2025 badge. `[36]` extends this over the whole flash
  dump: the bootloader and every populated app slot, each in its own subdir.
  Every headless pass finishes by triaging its own decompilation into a ranked
  `code-leads.txt` (`gh-leads.py`), cross-referencing the strings/hashes `[35]`
  already found against the functions that use them. It also recovers strings
  the firmware assembles at runtime, extracts comparison operands, applies ROM
  symbol names (`rom-syms.py` + `Enrich.java`), and writes string<->function
  cross-reference reports. The IDF/Arduino de-noiser is now scriptable too: `[37]`
  builds a symbolised reference ELF from the matching arduino-esp32 core (any
  version), which Ghidra FunctionID/BinDiff matches against the dump to name the
  SDK functions ([name-recovery.md](name-recovery.md)); the apply is a GUI step.

The items below are deliberately deferred, not forgotten. Each notes what
would trigger building it.

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
  different firmware versions on them. `[36]` now decompiles each populated
  slot into its own subdir; a direct app-descriptor / decompilation *diff*
  across slots is the remaining cheap, occasionally-decisive step.
- **Chip-off / SPI flash clip** — `flashrom` in a container with a CH341A
  programmer, for a badge whose download mode is fused off.
