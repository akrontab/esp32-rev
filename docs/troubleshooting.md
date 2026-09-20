# Troubleshooting

## The badge is not detected

Work down this list; it is ordered by how often each cause is the real one.

1. **Is it attached to the VM?** `[3]` should show the device as `ATTACHED`
   and report a `/dev/ttyUSB*` or `/dev/ttyACM*` node. If not, see
   [usb-passthrough.md](usb-passthrough.md).
2. **Is anything else holding the port?** Arduino IDE, PlatformIO, PuTTY or a
   previous serial monitor will hold it open. Close them.
3. **Is it a charge-only cable?** Extremely common. If Windows never showed a
   COM port for the badge, the cable has no data lines.
4. **Does it need help entering the bootloader?** Hold `BOOT`/`IO0`, tap
   `EN`/`RESET`, release `BOOT`, then retry. Some badges have no auto-reset
   circuit.
5. **Wrong baud for the console.** Detection uses esptool's own negotiation,
   but the *console* may be at 74880 (ESP ROM on some parts) rather than
   115200. Try `[8]` with 74880.

## A hardware command (chip ID, dump, ...) hangs

Usually a **stale serial node**. Native-USB parts (S3/C3/C6) re-enumerate on
reset/replug and come back as a higher-numbered node (e.g. `ttyACM1`), while the
old dead node (`ttyACM0`) lingers in the VM. Opening the dead node makes esptool
wait forever for a chip that never answers.

The control plane now resolves to the **newest** node automatically and warns
when several are present, so this should self-heal. If it still misbehaves, clear
the phantom node with a clean detach/re-attach from the USB device manager `[3]`
(detach, then attach), or check which node is live:

```powershell
wsl -d docker-desktop -- ls -lt /dev/ttyACM* /dev/ttyUSB*   # newest first
```

## The dump is all 0xFF or all 0x00

`esp-dump.sh` warns about this explicitly. It means the read was refused or
the chip is blank, not that you have a blank badge. Check `[6]` for read
protection and download-mode fuses.

## The dump is high-entropy noise

Triage will say `Almost everything is high entropy`. The flash is encrypted —
follow the encrypted-flash branch in [playbook.md](playbook.md#the-encrypted-flash-branch).

## `[12]` finds no partition table

Either the dump is encrypted, or the badge uses a non-standard table offset.
The pipeline falls back to scanning for image headers at sector boundaries and
prints what it finds, which is usually enough to carve manually.

## Filesystem extraction finds nothing

The partition may use a non-default geometry. SPIFFS defaults assumed here are
page 256 / block 4096 / name length 32; LittleFS is tried at 4096, 8192, 512
and 256 byte blocks. If the badge changed `sdkconfig`, run the parser by hand
in the analysis shell (`[22]`):

```bash
python3 -c "
import spiffsfmt
cfg = spiffsfmt.SpiffsConfig(page_size=256, block_size=8192)
r = spiffsfmt.scan(open('/work/parts/storage.bin','rb').read(), cfg)
print([(f.name, f.size) for f in r.files])"
```

## The hunt finds nothing

- Lower the threshold: `MINLEN=4` (set it in the analysis shell).
- Add the challenge's actual flag format to `workspace/<target>/patterns.txt`,
  one ripgrep regex per line, then re-run `[17]`. These extend the built-in
  patterns rather than replacing them.
- Check `reports/strings.txt` directly — the pattern list is a starting point,
  not a substitute for reading.
- If a pattern is malformed the hunt now says `INVALID PATTERN` rather than
  reporting no matches.

## Docker build fails

Re-run with no-cache from Build images (Setup `[1]` → `[2]`). If a Debian package genuinely disappeared,
the failure names it; see [decisions.md D10](decisions.md#d10--radare2-dropped-from-the-analysis-image)
for how the last such case was handled.

## The venv does not build

Container tooling is unaffected — only `[19]` and `[20]` need it. The control
plane says so and carries on. If you want it working, ensure a real Python
3.8+ is on `PATH` (the Microsoft Store stub is detected and skipped), then
`[V]` to rebuild.

## PowerShell refuses to run the script

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\badge.ps1
```

Venv activation itself does not need a policy change — it sets the environment
directly instead of running `Activate.ps1`.

## BLE scan/dump finds nothing or won't connect

A BLE peripheral accepts one central at a time — close nRF Connect or any other
connection to the badge and retry. Full detail: [ble.md](ble.md). BLE runs
host-side; if it reports bleak missing, run `[V]` to rebuild the venv.

## WiFi scan shows no badge AP

The badge may not host an access point — run `[31]` first to see whether the
firmware even uses SoftAP (the 2025 badge uses ESP-NOW, no AP). If it should
host one, power-cycle it and rescan; SoftAP often starts only in a certain mode.
See [wifi.md](wifi.md).

## hashcat: "No devices found" / falls back to CPU

The GPU isn't reaching the container. Check `docker run --rm --gpus all
nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi` works. The image must use the
`-devel-` CUDA base (for `libnvrtc`) and run with `NVIDIA_DRIVER_CAPABILITIES=all`
— the control plane sets both. See [hash-cracking.md](hash-cracking.md).

## A menu action seems to run but prints nothing

Interactive use is fine; this only happens when driving the menu with *piped*
input (e.g. scripted testing) for actions that stream subprocess output. Run the
tool directly (or use the container/host shell) if you need captured output.

## `[34]` Ghidra GUI: container exits instead of starting

If it prints "Starting virtual display + VNC" and then dies, the image's
TigerVNC (>= 1.15) is refusing an unauthenticated non-local bind. Fixed in
`gh-gui.sh`; **rebuild the ghidra image** to pick it up (Setup `[1]` → Build
images `[2]` → ghidra `[5]` — fast, only the script layer rebuilds). If it starts
but exits after a couple of seconds, that's the same fix (the container now
waits on the noVNC bridge, not the `ghidraRun` launcher, which forks and
returns). Full name-recovery flow and the "where's Function ID?" plugin gotcha
are in [name-recovery.md](name-recovery.md).
