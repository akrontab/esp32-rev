# Bluetooth Low Energy challenges

Many badges — including the 2025 one this toolkit was validated against — hide
challenges behind **BLE**. The badge is a BLE *peripheral*; you act as a
*central*: scan for it, connect, walk its GATT table, and read/write
characteristics. On the 2025 badge the entire challenge set (cipher strings, a
"Crack the Hash" pair, challenge banners) was readable this way.

---

## Why BLE runs on the host, not in a container

Everything else in this toolkit runs in Docker. BLE is the one exception, for a
hard technical reason rather than convenience.

**Bluetooth cannot be containerised on Docker Desktop / WSL2.** This was tested
directly:

- Passing an Intel adapter into the Docker VM with usbipd attaches it at USB
  level, but no `hci` interface appears — the minimal VM has no
  `/lib/firmware/intel`, and Intel adapters upload firmware at init.
- Even ignoring the radio, a container cannot open the Bluetooth socket family
  at all: `socket(AF_BLUETOOTH, …)` fails with `EAFNOSUPPORT` **even
  `--privileged` with `--net=host`** and `bluetooth.ko` loaded in the VM. The
  WSL2 VM kernel does not expose the Bluetooth stack to containers, so
  `bluetoothd` cannot start (`Failed to access management interface`).

So the container approach is a dead end for BLE. The clean answer is already in
the toolkit: the **host venv**. `bleak` has a native Windows backend (WinRT)
that drives the Bluetooth adapter Windows already manages — no usbipd, no
firmware, no radio passthrough, and it does not take Bluetooth away from
Windows. This is the sanctioned host-side exception the venv exists for.

```
  Windows Bluetooth stack (your built-in adapter)
        ^
        |  bleak WinRT backend
  .venv python  <--  scripts/host/ble/*.py
        ^
        |  WORK=workspace\<target>
  control plane menu [25]/[26]/[27]
```

---

## Prerequisites

- Windows Bluetooth on, and the adapter working (it already is if Windows sees
  BLE devices).
- The host venv built with `bleak` — the control plane installs it from
  `requirements.txt` on first run. If BLE options report bleak missing, run
  `[V]` to rebuild the venv.
- Windows may prompt once to allow the app to use Bluetooth — approve it.

No image to build, and no `[3]` USB attach — BLE ignores usbipd entirely.

---

## The workflow

### 1. Scan — `[25]`

Finds advertising devices, strongest signal first, and saves
`reports/ble-scan.json`. The badge shows up by name; note its **BD address**
(e.g. `BC:E1:00:07:0D:03`). RSSI is a rough distance guide — hold the badge to
the laptop and it will be near the top.

### 2. Dump the GATT table — `[26]`

Connect to that address and read **every** readable characteristic in one
pass. This is usually the whole job on a BLE badge. Output:

- `reports/ble-gatt.txt` — the service/characteristic tree with values
- `meta/ble-gatt.json` — machine-readable version
- `extract/ble/char_<handle>_<uuid>.bin` — every value as raw bytes

Printable values are shown inline; opaque ones get **decode hints** for the
common CTF encodings (rot13, base64, base32), because those were exactly the
2025 cipher transforms. Example from the real badge:

```
service 5b1efd49-02d1-46b3-9e4d-e7385878a19d
  char 79ff92fb-...  [read]  value: '--- Crack the Hash ---'
  char 7d10c989-...  [read]  value: 'f70f63def2543f77ff268579dd6ece12d0f7fc78'
```

### 3. Notifications / write — `[27]`

Some challenges do not hand you the answer on a plain read. They push data via
**notifications** (often after you *write* a trigger value, or on a timer). This
subscribes to a characteristic and logs what arrives to
`logs/ble-notify-*.log`, optionally writing first:

```
ble-notify.py <addr> --notify <char-uuid> --write <char-uuid>=<hex-or-string>
```

---

## Reading a GATT dump

- **Services** group **characteristics**; each characteristic has a UUID,
  **properties** (`read`/`write`/`notify`/`indicate`) and a value.
- **16-bit UUIDs** like `00002a00` are standard (Device Name, Appearance, …) —
  SDK boilerplate, rarely the challenge.
- **128-bit UUIDs** like `5b1efd49-...` are the badge's **custom** services.
  This is where challenge content lives. Read those first.
- A `write`-only or `notify` characteristic with no readable value is a hint
  that the challenge is *interactive* — use `[27]`.

---

## Concurrency gotcha

A BLE peripheral accepts **one central connection at a time**. If a dump fails
to connect, make sure nothing else holds the badge — a phone's nRF Connect, a
previous dump still closing, or another laptop. Wait a few seconds and retry.

---

## The phone is still a fine tool

The badge is designed to be poked with **nRF Connect** (iOS/Android) — it even
says so in its own strings. For quick interactive exploration at the contest, a
phone is genuinely fast. The value of the toolkit's BLE support is
**automation and record-keeping**: one command reads every characteristic into
hashed, timestamped workspace files you can grep, diff and cite — rather than
squinting at a phone screen and copying by hand.

---

## If you want BLE sniffing later

Reading a badge's own GATT covers most challenges. Capturing traffic *between*
the badge and another device (to watch a pairing or a notification exchange)
is a different job needing dedicated hardware — an nRF52840 dongle running
Sniffle, or a TI CC26x2. That is a roadmap item, not built yet; see
[roadmap.md](roadmap.md).
