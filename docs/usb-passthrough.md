# Getting the badge into a container on Windows

This is the part of the setup most likely to fail, and the errors are
unhelpful, so it gets its own document.

## The problem

Docker Desktop runs Linux containers inside a WSL2 virtual machine. A USB
serial adapter enumerated by Windows appears as `COM7`; the VM has no
knowledge of it, and `docker run --device=COM7` is meaningless. There is no
Docker Desktop setting that bridges the two.

## The solution

USB/IP. `usbipd-win` shares the device from Windows over USB/IP, and the WSL2
kernel attaches it as a real USB device. Critically, we attach it to the
**`docker-desktop` distro** — the VM Docker runs containers in — so the device
node exists in the same kernel namespace the container will use.

```
Windows host                          docker-desktop WSL2 VM
+-------------------+                 +---------------------------+
| badge (10c4:ea60) |                 |                           |
|        |          |                 |  vhci_hcd                 |
|   usbipd bind     | --- USB/IP ---> |     |                     |
|   usbipd attach   |                 |  cp210x driver            |
+-------------------+                 |     |                     |
                                      |  /dev/ttyUSB0             |
                                      |     |                     |
                                      |  docker run --device      |
                                      |     -> container          |
                                      +---------------------------+
```

The control plane does all of this for you (`[3]` USB device manager). What
follows is what it is doing, and how to fix it by hand.

## Prerequisites, and how they were verified here

| Requirement                    | Status on this machine                                         |
| ------------------------------ | -------------------------------------------------------------- |
| `usbipd-win` installed         | 5.3.0                                                          |
| Docker Desktop on WSL2 backend | yes, `docker-desktop` distro present                           |
| WSL2 kernel with USB/IP        | 6.6.87.2, `vhci-hcd` loads                                     |
| USB-serial drivers in the VM   | `cp210x`, `ch341`, `ftdi_sio`, `pl2303`, `cdc-acm` all present |

That last row matters: it means CP2102, CH340/CH9102, FTDI and native-USB
(S2/S3/C3) badges will all enumerate without building a custom kernel.

## Doing it manually

```powershell
usbipd list                                    # find the BUSID
usbipd bind --busid 1-4                        # Administrator, once per device
usbipd attach --wsl docker-desktop --busid 1-4
wsl -d docker-desktop -- ls -l /dev/ttyUSB*    # confirm the node appeared
docker run --rm -it --device=/dev/ttyUSB0:/dev/ttyUSB0 esp32-re/esptool bash
```

To release it back to Windows:

```powershell
usbipd detach --busid 1-4
```

`bind` is persistent across reboots; `attach` is not.

## Auto-attach, and why you want it

Menu option `[3] -> p` runs `attach` with `--auto-attach`. Parts with native
USB (ESP32-S2/S3/C3/C6) **re-enumerate every time they reset** — including the
automatic reset esptool performs before each operation. Without auto-attach
the device vanishes from the VM mid-session and the next command fails with a
confusing "port not found".

Auto-attach holds a console window open. Closing it stops re-attaching.

## Failure modes

### `usbipd attach` succeeds but no `/dev/ttyUSB*` appears

The device attached, but no driver claimed it. Check what the kernel saw:

```powershell
wsl -d docker-desktop -- dmesg | tail -20
```

- A `cdc_acm` device appears as `/dev/ttyACM0`, not `ttyUSB0`. The control
  plane looks for both.
- An unknown VID:PID with no matching driver will attach and do nothing. This
  is rare on badges but happens with exotic bridges.

### `vhci_hcd` not loaded

Docker Desktop does not load it at boot. The control plane loads it on every
attach; by hand:

```powershell
wsl -d docker-desktop -- modprobe vhci-hcd
```

### The device disappears after a reset

Expected on native-USB parts. Use auto-attach (`[3] -> p`).

### `usbipd bind` fails with an access error

`bind` and `unbind` need Administrator. The control plane raises a single UAC
prompt for just that command rather than requiring the whole session to be
elevated. `attach` and `detach` do not need it.

### The port works in the container but esptool cannot sync

That is no longer a passthrough problem — see
[troubleshooting.md](troubleshooting.md#the-badge-is-not-detected).

## Why not just run esptool on Windows?

It would work, and it is the standard advice. It is excluded here because the
project's constraint is that tooling stays out of the host environment. The
one deliberate exception is `usbipd`, which is a driver-level component with
no alternative — there is no way to reach a Linux container without it.

If USB/IP is genuinely unavailable on some machine, the documented fallback is
to install `esptool` into the project `.venv` and drive the COM port directly;
`requirements.txt` does not include it by default precisely because that
crosses the line the project draws.
