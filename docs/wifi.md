# WiFi capability recon

Every ESP32 has WiFi, and a badge may use it as a station (joining a network),
a SoftAP (hosting its own), for ESP-NOW (peer-to-peer, badge-to-badge), or for
provisioning (SmartConfig/WPS). This covers **reconnaissance** — working out
what the badge can do and what it has been configured with. It is not an attack
toolkit (see [Scope](#scope)).

Two halves, split the same way as BLE:

- **Offline, from the dump** (`[31]`, analysis container) — what WiFi features
  the firmware uses, and any stored WiFi config/credentials.
- **Live, from the host** (`[32]`, venv via the Windows WLAN service) — a
  passive scan to spot the badge's own access point.

---

## Offline: capabilities from the firmware — `[31]`

Reads the dump (needs the analysis pipeline's `parts/` and, ideally,
`reports/strings.txt`) and reports two things.

**Stored WiFi config (from NVS).** ESP-IDF keeps WiFi settings in the NVS
namespace `nvs.net80211`: `opmode` (STA/AP/APSTA), `sta.ssid` / `sta.pswd`,
`ap.ssid` / `ap.passwd`, and so on. A provisioned badge often has real
credentials sitting here in the clear — and, because NVS keeps erased entries
until compaction, **old** credentials too. SSIDs and passwords are pulled out
of the config blobs as printable text.

**Features used by the firmware.** Which of these the code actually references,
ranked by weight of evidence: SoftAP, station, ESP-NOW, mesh, SmartConfig, WPS,
promiscuous/monitor mode, scanning, and an HTTP server / captive portal.

Output: `reports/wifi.txt`, `meta/wifi.json`.

Example — the 2025 badge reports **ESP-NOW**, an **HTTP server**, and
**SmartConfig**, with no stored station credentials. That immediately tells you
the badge talks badge-to-badge over ESP-NOW rather than joining WiFi, which is
a different surface than "find its AP".

---

## Live: scan for the badge's SoftAP — `[32]`

A passive scan via `netsh wlan show networks` on the Windows host, listing
SSID, auth, signal and channel. Open networks and anything whose name looks
badge-ish (badge/ctf/esp/event names) are floated to the top and flagged.

Output: `reports/wifi-scan.json`, `reports/wifi-scan.txt`.

If the badge hosts an **open** AP, connect to it from Windows and probe its
services — the firmware analysis above will have told you if there's an HTTP
server to hit. If the SoftAP only appears in a certain mode, power-cycle the
badge (or trigger the mode) and rescan.

This runs host-side for the same reason as BLE: a Docker Desktop container has
no access to a wireless adapter or the WiFi stack. See [ble.md](ble.md#why-ble-runs-on-the-host-not-in-a-container)
— the WiFi case is if anything harder (monitor mode, nl80211).

---

## ESP-NOW

If `[31]` flags ESP-NOW (as the 2025 badge does), the badge exchanges data with
other badges over a connectionless WiFi-based protocol — no AP, no association.
Reading it live needs a second ESP32 running promiscuous/ESP-NOW capture (a
natural companion tool, not yet built — see [roadmap.md](roadmap.md)). Offline,
the firmware strings and any stored peer list are still informative.

---

## Scope

This is capability enumeration, deliberately. **Not** included: deauth,
handshake capture, monitor-mode sniffing, or rogue APs. Those need a dedicated
adapter with monitor mode and a real Linux host (not a Docker Desktop
container), and they are attack rather than recon — noted in
[roadmap.md](roadmap.md) if a challenge ever calls for them.

## What leaves your machine

Nothing. Offline analysis reads local files; the live scan is passive receive
only — it associates with nothing and transmits nothing.
