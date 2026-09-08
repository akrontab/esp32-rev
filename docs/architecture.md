# Architecture

## Shape

```
              PowerShell control plane  (scripts/badge.ps1)
              state | usbipd | docker | venv
                              |
   containers  +--------------+--------------+---------------+
               |              |              |               |
        esp32-re/esptool  esp32-re/analysis  esp32-re/hashcat |
        --device=serial   no device, ever    --gpus all       |
               |              |  (fw-wifi)     (local crack)   |
               +--------------+--------------+---------------+-+
                              |                              |
                    workspace/<target>  <---- host venv (.venv) ----+
                    (bind-mounted /work)      verify | summary       |
                              ^               BLE (bleak, Windows)   |
                              |               WiFi scan (netsh)      |
                    Linode rig (Terraform, by hand) --- escalation --+
                    remote GPU for heavy hash cracking
```

Everything shares one thing: `workspace/<target>`, the unit of work — one
directory per badge holding every artefact, report and log. Containers reach it
as a bind mount at `/work`; host-side tools (BLE, WiFi, verify) write into it
directly.

Two things run **outside** containers on purpose, because Docker Desktop/WSL2
cannot give a container the hardware they need:
- **BLE and WiFi** — no Bluetooth socket family or wireless adapter in
  containers, so they run in the venv against the Windows stack ([ble.md](ble.md),
  [wifi.md](wifi.md)).
- **The Linode cracking rig** — a remote GPU box the user brings up by hand
  with Terraform only when local cracking stalls ([hash-cracking.md](hash-cracking.md)).

## Why a control plane at all

Under contest pressure the failure mode is not "I don't know the command", it
is "I ran the right command against the wrong target, or forgot to hash the
dump, or can't remember whether I already read the eFuses". A single menu that
carries the selected target, the attached device and the provenance ledger
removes that whole class of mistake.

It also means the tedious parts — bind/attach, path translation, environment
variables, flash-size detection, baud fallback — happen the same way every
time.

## Container-side conventions

Every tool sources `/opt/re/lib/common.sh`, which provides:

- fixed workspace paths (`$DIR_DUMPS`, `$DIR_PARTS`, `$DIR_REPORTS`, ...)
- `log` / `ok` / `warn` / `die` output helpers that stay clean when piped
- `record <action> <detail>` — appends a JSON line to `logs/actions.jsonl`
- `register_artifact <path>` — hashes a file into `meta/artifacts.sha256`
- `esp` — an esptool wrapper that applies port and chip consistently

A new tool therefore gets provenance, logging and consistent paths for free,
which is the point: adding a tool mid-contest should be a ten-line script.

Shared Python parsers live in `/opt/re/lib` and are on both `PYTHONPATH` and
`PATH`, so a CLI like `esp-parts.py` exists once and both images can run it.

## Environment contract

The control plane passes these into every container:

| Variable | Meaning |
|---|---|
| `WORK` | always `/work`, the mounted target workspace |
| `TARGET` | target name, recorded in the action log |
| `SERIAL_PORT` | device path; set only for the esptool image |
| `BAUD` | flash read speed, with automatic fallback to 115200 |
| `CHIP` | `auto`, or a pinned esptool chip id once known |

## Host state

`.badge-state.json` holds the selected target, attached bus id, device path
and baud between runs. It is machine-local and git-ignored — it describes
which badge is plugged into *this* laptop.

## Where the design deliberately stops

- **No write path to the badge.** See [decisions.md D5](decisions.md#d5--read-only-toward-the-badge).
- **No disassembler yet.** Quick looks are covered by strings, image parsing
  and riscv64 objdump; real disassembly is Ghidra's job, still a deferred image
  ([roadmap.md](roadmap.md)).
- **Wireless is recon, not attack.** BLE (scan/GATT) and WiFi (capabilities +
  SoftAP scan) enumerate the badge; deauth, handshake capture and monitor-mode
  sniffing need dedicated hardware and a real Linux host, and are out of scope
  ([wifi.md](wifi.md), [roadmap.md](roadmap.md)).
