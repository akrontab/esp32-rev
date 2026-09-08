# Background: understanding an ESP32 dump

A primer for reading the output this toolkit produces. Assumes you know what a
microcontroller, flash memory and a serial port are, but nothing ESP32-specific.

Every example is real output from `workspace/badge-2025` — an ESP32-S3 badge
with 8 MB of flash — so you can follow along against actual files.

---

## 1. The mental model

An ESP32 is a microcontroller with **no internal program storage**. The code
lives in a **separate SPI flash chip** on the board, and the CPU reads it over
a 4-wire SPI bus. That single fact is why this toolkit works at all: dumping
the flash chip gets you the entire firmware, because there is nowhere else for
it to be.

```
   ESP32-S3 chip                     SPI flash chip (separate part)
  +----------------------+          +---------------------------+
  |  CPU (Xtensa LX7)    |          |  0x000000  bootloader     |
  |  internal SRAM       |<-- SPI ->|  0x008000  partition table|
  |  ROM (mask, fixed)   |          |  0x009000  nvs            |
  |  eFuses (OTP bits)   |          |  0x010000  app0           |
  +----------------------+          |  ...                      |
                                    +---------------------------+
```

Three storage areas matter, and they behave very differently:

| Storage | Where | Can we read it? | Notes |
|---|---|---|---|
| **SPI flash** | External chip | **Yes** — this is the dump | Everything interesting |
| **eFuses** | Inside the chip | Yes, via `espefuse` | One-time programmable; the security config |
| **ROM** | Inside the chip | Not over serial | Fixed by Espressif, same for all chips |

The boot sequence is: **ROM bootloader** (burned into the chip, runs first,
speaks the serial protocol esptool uses) → **second-stage bootloader** (from
flash offset 0x0 on the S3) → reads the **partition table** → picks an app
partition → jumps into your firmware.

---

## 2. eFuses: the chip's permanent configuration

**eFuses are one-time programmable bits.** Physically, burning a fuse is
destructive — a bit goes from 0 to 1 and *can never go back*. There is no
erase. This is why the toolkit never writes them: a mistake is permanent and
bricks the badge.

They hold the MAC address, the security policy, and hardware options. Read
them with menu `[6]`; results land in `meta/efuse_summary.txt` and the
interpreted version in `reports/security-posture.txt`.

### Reading an espefuse line

```
SPI_BOOT_CRYPT_CNT (BLOCK0)   Enables flash encryption when 1 or 3 bits are set = Disable R/W (0b000)
^^^^^^^^^^^^^^^^^^  ^^^^^^                                                        ^^^^^^^ ^^^ ^^^^^
fuse name           block     description                                         value   |   raw bits
                                                                                          protection
```

The `R/W` field is the part beginners miss. It describes **whether the fuse is
still readable and writable**, not its value:

| Marker | Meaning |
|---|---|
| `R/W` | Readable and still writable — nothing locked |
| `R/-` | Readable, **write-protected** — value is frozen forever |
| `-/W` | **Read-protected** — the chip refuses to show it (typical of key material) |
| `-/-` | Both — the fuse is set and permanently hidden |

A key you cannot read (`-/-`) is not a bug; it is the chip doing its job. On
your badge every key block reads `USER/EMPTY` with `R/W`, meaning no keys were
ever burned.

### The fuses that decide your whole approach

These are the ones to look at first, with your badge's actual values:

| Fuse | Your badge | What it means if set |
|---|---|---|
| `SPI_BOOT_CRYPT_CNT` | `0b000` (Disable) | **Flash encryption.** Your dump would be ciphertext |
| `SECURE_BOOT_EN` | `False` | **Secure boot.** Chip refuses unsigned firmware |
| `DIS_DOWNLOAD_MODE` | `False` | Serial bootloader disabled — **no dumping at all** |
| `DIS_PAD_JTAG` | `False` | JTAG physically disabled |
| `SOFT_DIS_JTAG` | `0b000` | JTAG disabled in software |
| `RD_DIS` | `0` | Bitmask of key blocks made unreadable |
| `WR_DIS` | `0` | Bitmask of fuses frozen against further writes |
| `SECURE_VERSION` | `0` | Anti-rollback counter; blocks older firmware |

**All zero means completely unlocked** — which is why your badge dumped
cleanly. That is the common case for conference badges, because locking one
down costs the organisers manufacturing effort and gains them nothing.

> **The odd counter.** `SPI_BOOT_CRYPT_CNT` is not a boolean. It is a 3-bit
> counter where **an odd number of set bits means encryption is ON** and an
> even number means OFF. This lets a manufacturer toggle it a limited number
> of times (0 bits → 1 bit → 2 bits → 3 bits). If you see `0b001` or `0b111`,
> the flash is encrypted.

### What flash encryption actually does to you

The flash contents are encrypted with a key held in an eFuse block that is
read-protected. The chip decrypts transparently as the CPU fetches, so the
firmware runs normally — but a serial dump reads the *raw* flash and gets
ciphertext. Triage detects this: entropy will be ~8.0 everywhere and the
report says so explicitly. You cannot decrypt it offline without the key,
which is the point.

---

## 3. The partition table

At **offset 0x8000** sits a 4 KB table of 32-byte entries describing how the
rest of flash is divided. This is the map for everything else.

Your badge (`reports/partitions.txt`):

```
#  label      type  subtype   offset      size       size_kb
0  nvs        data  nvs       0x00009000  0x00005000  20
1  otadata    data  otadata   0x0000e000  0x00002000  8
2  app0       app   ota_0     0x00010000  0x00330000  3264
3  app1       app   ota_1     0x00340000  0x00330000  3264
4  spiffs     data  spiffs    0x00670000  0x00180000  1536
5  coredump   data  coredump  0x007f0000  0x00010000  64
```

Laid out visually across the 8 MB chip:

```
0x000000  bootloader        (not in the table - fixed location)
0x008000  partition table   (not in the table - describes the rest)
0x009000  nvs          20K  key/value config store
0x00e000  otadata       8K  which app slot to boot
0x010000  app0       3264K  <- firmware currently running
0x340000  app1       3264K  <- OTA update slot (BLANK on your badge)
0x670000  spiffs     1536K  filesystem (BLANK on your badge)
0x7f0000  coredump     64K  crash dumps (BLANK on your badge)
```

### What each partition type means

**`app` (ota_0 / ota_1 / factory)** — executable firmware images. The dual
`app0`/`app1` layout is the standard **OTA update** scheme: the device runs
from one slot, downloads an update into the *other* slot, then flips a pointer
and reboots. Two slots exist so a failed update cannot brick the device.

**`otadata`** — the pointer that says which app slot to boot. Tiny, but it is
what makes the OTA scheme work.

**`nvs`** — Non-Volatile Storage, a key/value database (section 5). This is
where WiFi credentials, tokens and device config live. **Highest-value target
after the app itself.**

**`spiffs` / `littlefs` / `fat`** — a real filesystem holding files: web
assets, certificates, images, config. Extracted by `[15]` into `extract/`.

**`coredump`** — if the firmware crashed, ESP-IDF can write a snapshot of
registers and stack here. A populated coredump on a badge means it crashed at
some point, and the snapshot can be informative.

### Reading meaning into what is *blank*

On your badge, `app1`, `spiffs` and `coredump` are all `0xFF` — never written.
That is not an absence of data, it is evidence:

- **`app1` blank** → no OTA update was ever applied. The badge is running its
  factory firmware.
- **`spiffs` blank** → the firmware declares a filesystem but never uses it.
- **`coredump` blank** → it never crashed hard enough to record one.

During a live event, an `app1` that *becomes* populated is a strong signal
that something was pushed to the badge — worth dumping before and after.

---

## 4. Application images: what is inside `app0.bin`

An app partition holds an **ESP image**, a simple container format. It starts
with magic byte `0xE9`, a 24-byte header, then a series of **segments**, then
a checksum byte and usually a SHA-256.

A segment is just: *"load this many bytes at this address."* The bootloader
either copies the segment into RAM or configures the memory-mapping unit to
expose it directly from flash.

Your badge's app0, from `reports/triage.txt`:

```
0x00010000  ESP32-S3  5 segments  entry 0x40377530  flash 8MB/DIO/80MHz
    project 'arduino-lib-builder'  idf v4.4.7-dirty  built Mar 5 2024 12:12:53
    seg0 load=0x3c0b0020 len=0x30a54   entropy=5.65
    seg1 load=0x3fc97290 len=0x4d1c    entropy=4.46
    seg2 load=0x40374000 len=0xa878    entropy=6.94
    seg3 load=0x42000020 len=0xa224c   entropy=7.21
    seg4 load=0x4037e878 len=0x8a0c    entropy=7.03
```

### Decoding those load addresses

The address tells you what the segment *is*. For the ESP32-S3:

| Address range | Name | Contains |
|---|---|---|
| `0x3C000000`–`0x3D000000` | **DROM** | Constant data, mapped from flash — **strings live here** |
| `0x3FC80000`–`0x3FCF0000` | **DRAM** | Read/write data, copied into internal SRAM |
| `0x40370000`–`0x403E0000` | **IRAM** | Code copied into internal SRAM (fast/interrupt code) |
| `0x42000000`–`0x44000000` | **IROM** | Executable code, mapped from flash — **the bulk of firmware** |

So your badge's segments are:

- **seg0 @ `0x3c0b0020`** → DROM, 195 KiB — constants and string literals
- **seg1 @ `0x3fc97290`** → DRAM, 19 KiB — initialised variables
- **seg2 @ `0x40374000`** → IRAM, 42 KiB — time-critical code
- **seg3 @ `0x42000020`** → IROM, **649 KiB — this is the actual program**
- **seg4 @ `0x4037e878`** → IRAM, 34 KiB — more RAM-resident code

That is 939 KiB of firmware in total, and roughly two thirds of it is the
single IROM segment.

Ranges differ per chip family — the original ESP32 uses `0x3F400000` for DROM
and `0x400D0000` for IROM. The toolkit prints whatever the image declares, so
you do not have to memorise them.

**Why this matters:** when you eventually load `app0.bin` into a disassembler,
you must map each segment at its load address. Get it wrong and every function
call points at nonsense. Those addresses in `triage.txt` are exactly the
numbers you will type into Ghidra.

### The app descriptor

At offset `0x20` of an app image sits a 256-byte struct with build metadata,
which is why triage can tell you:

- `project 'arduino-lib-builder'` — built with the **Arduino core**, not raw
  ESP-IDF. Expect Arduino APIs (`setup()`, `loop()`, `Serial`, `WiFi`).
- `idf v4.4.7-dirty` — the SDK version. Hugely useful: you can build the same
  version yourself and diff, to separate *badge code* from *SDK code*. On a
  939 KiB image that is mostly SDK, that is the single biggest time-saver
  available.
- `built Mar 5 2024` — when the firmware was compiled.

### Entropy, and what it tells you

Entropy measures randomness, 0–8 bits per byte:

| Value | Typically means |
|---|---|
| 0.0 | All one byte — blank/erased flash |
| 1–5 | Text, tables, sparse data |
| 5–7 | **Compiled code** (your segments: 5.65–7.21) |
| 7.5–8.0 | Compressed or **encrypted** |

The entropy map in `triage.txt` draws this across the whole chip, so you can
see at a glance which regions hold something. A dump that is ~8.0 everywhere
is encrypted, and no amount of `strings` will help.

---

## 5. NVS: where secrets actually live

NVS is a key/value store, organised as 4 KB pages holding 32-byte entries.
Values are grouped into **namespaces** (like tables in a database).

Your badge (`reports/nvs-nvs.txt`):

```
namespaces: 1=phy, 2=bt_config.conf

[written] phy             blob_data  cal_data    = <1904 bytes>
[written] phy             u32        cal_version = 640
[erased ] bt_config.conf  blob_data  bt_cfg_key0 = <62 bytes>
[erased ] bt_config.conf  blob_data  bt_cfg_key0 = <113 bytes>
[erased ] bt_config.conf  blob_data  bt_cfg_key0 = <165 bytes>
[written] bt_config.conf  blob_data  bt_cfg_key0 = <216 bytes>
```

`phy` is radio calibration written by the SDK. `bt_config.conf` is Bluetooth
pairing state. Neither is secret — but on a badge that stores WiFi
credentials, an API token or a flag, *this is where it will be*.

### Why "erased" entries are the interesting ones

**Flash cannot overwrite in place.** Changing a value means writing a new copy
elsewhere and marking the old one erased — a bookkeeping flag, not a wipe. The
old bytes sit there until the page is compacted.

So `[erased]` entries are **previous values still readable on the chip**. Your
badge shows the Bluetooth config growing 62 → 113 → 165 → 216 bytes across
four writes; all four are recovered into `extract/nvs_blobs/`, named by page,
entry and state.

On a CTF badge this is often the whole challenge: a flag written once, then
overwritten, is still sitting in the erased entry. The toolkit reports erased
entries by default for exactly this reason.

---

## 6. Reading the reports

After `[9]` acquire and `[12]` analyse, in the order worth reading:

| File | What it answers |
|---|---|
| `reports/security-posture.txt` | **Read first.** Is anything locked? |
| `reports/hunt.txt` | Flag/credential pattern hits, with source files |
| `reports/triage.txt` | What the dump is: entropy map, images, segments |
| `reports/partitions.txt` | The flash map |
| `reports/nvs-*.txt` | Config values, including erased ones |
| `reports/strings.txt` | Every string, prefixed with its source file |
| `parts/` | One `.bin` per partition |
| `extract/` | Files recovered from filesystems and NVS blobs |
| `meta/artifacts.sha256` | Hashes — `[19]` re-verifies |

A hunt line reads source-first, so you always know where a hit came from:

```
194:extract/storage/flag.txt: CTF{...}
     ^ file it came from       ^ the match
```

---

## 7. Vocabulary

| Term | Meaning |
|---|---|
| **eFuse** | One-time-programmable bit inside the chip. Never resets |
| **ROM bootloader** | Fixed code in the chip; speaks esptool's protocol |
| **Second-stage bootloader** | From flash; reads the partition table |
| **Partition table** | 4 KB map at 0x8000 |
| **OTA** | Over-The-Air update; the `app0`/`app1` two-slot scheme |
| **NVS** | Key/value config store |
| **SPIFFS / LittleFS** | Flash filesystems holding real files |
| **DROM / IROM** | Flash-mapped data / code |
| **DRAM / IRAM** | Internal SRAM data / code |
| **Segment** | "Load N bytes at address X" inside an app image |
| **App descriptor** | Build metadata at offset 0x20 of an app image |
| **Entropy** | Randomness 0–8; ~8 means encrypted or compressed |
| **Xtensa / RISC-V** | The two CPU architectures; S3 is Xtensa, C3/C6 are RISC-V |
| **Secure boot** | Chip refuses unsigned firmware |
| **Flash encryption** | Flash stored encrypted; dumps are ciphertext |

---

## 8. Where to go next

If `hunt.txt` finds nothing and NVS and the filesystems are empty — the
situation on this stock badge — the flag is either not present or is
constructed at runtime. That is the point where static analysis stops paying
and you either **disassemble** `app0.bin` (map those segments at their load
addresses; see [roadmap.md](roadmap.md)) or **watch the badge run** by
capturing its console with `[8]` while driving its buttons and menus.

For the order to work in during a live event, see
[playbook.md](playbook.md).
