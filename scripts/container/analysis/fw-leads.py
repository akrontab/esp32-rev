#!/usr/bin/env python3
"""Triage an arbitrary `strings` dump into signal vs noise, and bucket the signal.

A firmware strings file is ~50% SDK/RTOS/driver boilerplate with zero challenge
value. This drops that noise and groups what's left into the categories that
actually matter on a CTF badge - flag-shaped tokens, ciphers/encoded blobs,
credentials, hosts/URLs, hashes, and human-facing UI/lore text - so you read a
few hundred lines instead of ten thousand.

Works on any strings output:
  - the toolkit's reports/strings.txt (lines prefixed "source: text")
  - a raw `strings foo.bin` dump (no prefix)
  - stdin (--stdin)

  fw-leads.py [file]        default: reports/strings.txt
  fw-leads.py --stdin       read from stdin
  strings foo.bin | fw-leads.py --stdin

Writes reports/leads.txt (grouped, deduped, source-attributed) and
meta/leads.json. Prints the grouped leads.
"""

import json
import os
import re
import sys

WORK = os.environ.get("WORK", "/work")

# --- NOISE: a line matching any of these is SDK/framework/driver boilerplate.
# Ordered so the stats read usefully; matching is "any".
NOISE = [
    ("bluetooth-stack", re.compile(
        r"\b(BT_|BTM_|BTA_|BTU_|BTC_|L2CA|l2c_|GATTS?|GATTC|SMP_|smp_|HCI|hci_|"
        r"AVDT|AVCT|A2DP|AVRC|BLE_|bluedroid|nimble|ble_gap|ble_gatt|gap_|gatt_)", re.I)),
    ("esp-idf/driver", re.compile(
        r"\b(esp_|ESP_|nvs_|spi_flash|spiram|ledc|rmt_|i2c_|i2s_|uart_|gpio|"
        r"adc\d?|touch_|rtc_|dport|periph_|phy_|esp-idf|Cache_|xt_|intr_|pcnt|mcpwm|sdmmc)", re.I)),
    ("freertos", re.compile(
        r"\b(FreeRTOS|xQueue|xTask|xSemaphore|xEventGroup|pvPort|vTask|prvheap|"
        r"tskIDLE|portMUX|uxList|StreamBuffer|Timer Svc)", re.I)),
    ("net-lib", re.compile(r"\b(lwip|tcpip|dhcp|dns_|netif|sockets\.c|ppp|icmp|tcp_|udp_|mdns)", re.I)),
    ("crypto-lib", re.compile(r"\b(mbedtls|x509|ssl_|bignum|_sha\d|aes_|ecp_|rsa_|ccm_|gcm_)", re.I)),
    ("source-path", re.compile(
        r"(\.platformio|/IDF|components/|managed_components|framework-arduino|"
        r"[\w/]+\.(cpp|[ch]pp?|py|S)\b)")),
    ("format/panic", re.compile(
        r"(%[-0-9.*]*[dsuxXcpfl]|Guru Meditation|abort\(\)|assert|\bEPC\d|"
        r"Coprocessor exception|Debug exception|register dump|backtrace|"
        r"CORRUPT HEAP|Stack canary|watchdog)", re.I)),
]

# --- SIGNAL buckets, applied to non-noise lines in priority order (first match
# wins). Tuned for CTF badges.
SIGNAL = [
    ("flag-format", re.compile(r"\b[A-Za-z][A-Za-z0-9_]{1,20}\{[^}]{2,80}\}|CTF|\bFLAG\b|WWHF|BHIS", re.I)),
    ("hash", re.compile(r"\b[0-9a-fA-F]{32}\b|\b[0-9a-fA-F]{40}\b|\b[0-9a-fA-F]{64}\b")),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.")),
    ("base64", re.compile(r"[A-Za-z0-9+/]{24,}={0,2}")),
    ("base32", re.compile(r"\b[A-Z2-7]{16,}={0,6}")),
    ("bacon-cipher", re.compile(r"\b[abAB]{5}(?:\s[abAB]{5}){2,}")),
    ("url/host", re.compile(r"[a-z][a-z0-9+.-]*://\S+|(?:\d{1,3}\.){3}\d{1,3}(?::\w+)?", re.I)),
    # Keyword-based only: high precision. A greedy "leet token" regex was tried
    # and rejected - it grabbed repeating binary junk (t00t@@t) while missing
    # real passwords (L3tM31n!), which land in human-text anyway.
    ("credential", re.compile(
        r"\b(pass(word|wd|phrase)?|user(name)?|login|admin|root|secret|token|"
        r"api[_-]?key|passkey|creds?)\b", re.I)),
]

# Human/lore/UI text: a fallback bucket for readable phrases the buckets above
# didn't claim - challenge prompts, banners, menu text.
HUMAN = re.compile(r"^[A-Za-z][A-Za-z0-9 ,.:;'!?/()_+-]{8,70}$")
# Common English/util words that make a line look human but carry no signal.
BORING = re.compile(
    r"\b(invalid|failed|error|unknown|cannot|unable|missing|buffer|length|"
    r"param|config|init|default|enable|disable|register|attribute|descriptor|"
    r"characteristic|service|connect|disconnect|timeout|version|memory|handle|"
    r"channel|frequency|calibrat|allocat|overflow|not support|out of range)\b", re.I)


def split_line(line):
    """Return (source, text). Handles 'source: text', otherwise ('', line)."""
    # reports/strings.txt uses "path: text" or "path(utf16): text".
    m = re.match(r"^([\w./\-]+(?:\(utf16\))?): (.*)$", line)
    if m:
        return m.group(1), m.group(2)
    return "", line


def classify(text):
    for name, rx in NOISE:
        if rx.search(text):
            return "noise:" + name
    for name, rx in SIGNAL:
        if rx.search(text):
            return name
    if HUMAN.match(text) and " " in text and not BORING.search(text):
        return "human-text"
    return "other"


def main():
    args = [a for a in sys.argv[1:] if a != "--stdin"]
    use_stdin = "--stdin" in sys.argv[1:]

    if use_stdin:
        lines = sys.stdin.read().splitlines()
        src_label = "<stdin>"
    else:
        path = args[0] if args else os.path.join(WORK, "reports", "strings.txt")
        if not os.path.isfile(path):
            print("[x] no strings file: %s (run the hunt/pipeline first, or pass a file)" % path,
                  file=sys.stderr)
            return 1
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        src_label = os.path.relpath(path, WORK) if path.startswith(WORK) else path

    buckets = {}          # bucket -> {text: source}
    noise_counts = {}
    total = 0
    for line in lines:
        if not line.strip():
            continue
        total += 1
        source, text = split_line(line)
        cat = classify(text)
        if cat.startswith("noise:"):
            noise_counts[cat[6:]] = noise_counts.get(cat[6:], 0) + 1
            continue
        buckets.setdefault(cat, {})
        # dedupe on text; keep first source seen
        if text not in buckets[cat]:
            buckets[cat][text] = source

    noise_total = sum(noise_counts.values())
    signal_total = sum(len(v) for v in buckets.values())

    # --- render ---
    order = ["flag-format", "credential", "cipher-ish", "bacon-cipher",
             "base64", "base32", "jwt", "hash", "url/host", "human-text", "other"]
    # (cipher-ish isn't a real bucket; keep 'other' last)
    order = [b for b in order if b in buckets] + [b for b in buckets if b not in order]

    out = []
    out.append("# strings leads - %s" % src_label)
    out.append("# %d lines: %d signal, %d noise (%d%% noise filtered)"
               % (total, signal_total, noise_total,
                  (100 * noise_total // total) if total else 0))
    out.append("#")
    out.append("# noise filtered by category:")
    for name, n in sorted(noise_counts.items(), key=lambda kv: -kv[1]):
        out.append("#   %-18s %6d" % (name, n))
    out.append("")

    # cap per bucket so 'human-text'/'other' don't flood; the file keeps all.
    caps = {"human-text": 200, "other": 150}
    for b in order:
        items = sorted(buckets[b].items())
        out.append("## %s (%d)" % (b, len(items)))
        shown = items[:caps.get(b, 400)]
        for text, source in shown:
            prefix = (source + ": ") if source else ""
            out.append("  %s%s" % (prefix, text))
        if len(items) > len(shown):
            out.append("  ... and %d more" % (len(items) - len(shown)))
        out.append("")

    report = "\n".join(out)
    print(report)

    os.makedirs(os.path.join(WORK, "reports"), exist_ok=True)
    os.makedirs(os.path.join(WORK, "meta"), exist_ok=True)
    with open(os.path.join(WORK, "reports", "leads.txt"), "w", encoding="utf-8") as fh:
        fh.write(report + "\n")
    with open(os.path.join(WORK, "meta", "leads.json"), "w", encoding="utf-8") as fh:
        json.dump({
            "source": src_label, "total": total,
            "signal": signal_total, "noise": noise_total,
            "noise_by_category": noise_counts,
            "buckets": {b: sorted(v.keys()) for b, v in buckets.items()},
        }, fh, indent=2)

    print("[+] wrote reports/leads.txt and meta/leads.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
