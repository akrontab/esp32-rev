#!/usr/bin/env python3
"""Triage Ghidra's decompilation into a ranked shortlist of functions to read.

Headless analysis ([33]/[36]) emits decompiled.c with thousands of anonymous
FUN_* functions and no symbols. This is the code-side analogue of fw-leads: it
scores every function for challenge-relevance and writes the few dozen worth
reading first, so you don't grep 4,600 functions by hand.

Two kinds of signal:

  1. Ties back to what the rest of the toolkit already found. If meta/leads.json
     (from fw-leads) has flag tokens, credentials, or cracked hashes, a function
     that *references one of them* is almost always where the check lives. This
     is the strongest signal - it connects static strings to the code using them.

  2. Static heuristics on each function body: comparison primitives
     (strcmp/memcmp), XOR/shift-heavy code (custom ciphers/checksums),
     crypto/base64 constants, and challenge-flavoured keywords.

Reads (from the Ghidra output dir, default reports/ghidra):
    decompiled.c        required - the function bodies
    functions.txt       optional - address/name/size, to label each lead
    strings-ghidra.txt  optional - Ghidra's defined strings
And from the workspace: meta/leads.json, reports/hunt.txt (optional cross-ref).

Writes <dir>/code-leads.txt (ranked, with the reason for each) and
<dir>/code-leads.json. Prints the top of the list.
"""

import json
import os
import re
import sys

WORK = os.environ.get("WORK", "/work")

# --- comparison primitives: "does the input equal the secret?" checks.
CMP = re.compile(r"\b(strcmp|strncmp|strcasecmp|strncasecmp|memcmp|strstr)\b")

# --- challenge-flavoured text the firmware shows or checks against.
KEYWORD = re.compile(
    r"(?i)\b(flag|pass(?:word|phrase|wd)?|secret|unlock|correct|incorrect|"
    r"wrong|access granted|access denied|congrat|well done|nice try|you win|"
    r"you lose|try again|enter the|the code is|level\s*\d|authenticat|verif)\b")

# --- init constants / alphabets that give away crypto or encoding.
B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
B32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
CRYPTO_CONST = re.compile(
    r"0x67452301|0xefcdab89|0x98badcfe|0x10325476|"       # MD5 init
    r"0x6a09e667|0xbb67ae85|0x3c6ef372|0x5be0cd19|"       # SHA-256 init
    r"0x428a2f98|0x71374491|"                              # SHA-256 round const
    r"0xedb88320|0x04c11db7|"                              # CRC32 polynomials
    r"0x9e3779b9|0x61c88647",                              # TEA/XXTEA delta
    re.I)

# Comparison against a string literal on the same statement - the "expected"
# input a check is testing for (a password, a flag, an unlock word).
CMP_LITERAL = re.compile(
    r"\b(?:strcmp|strncmp|strcasecmp|strncasecmp|memcmp|strstr)\s*\([^;]*?"
    r'"((?:[^"\\]|\\.){2,64})"')

# A hex literal wide enough (>= 6 bytes) to be a stack-packed ASCII string
# rather than an address or mask. Ghidra renders runtime-built strings this way.
PACKED_HEX = re.compile(r"0x([0-9a-fA-F]{12,16})\b")


def decode_packed(hexdigits):
    """A wide hex literal, little-endian, that decodes to printable ASCII is
    almost always a string the firmware assembles at runtime to dodge `strings`.
    Return the decoded text, or None if it doesn't look like text."""
    if len(hexdigits) % 2:
        return None
    try:
        raw = int(hexdigits, 16).to_bytes(len(hexdigits) // 2, "little")
    except (ValueError, OverflowError):
        return None
    raw = raw.rstrip(b"\x00")
    if len(raw) < 4 or any(b < 0x20 or b > 0x7E for b in raw):
        return None
    if sum(chr(b).isalnum() for b in raw) < 4:      # reject printable-but-junk
        return None
    return raw.decode("ascii", "replace")

# Functions we never want to surface: SDK/RTOS/libc internals by name.
BORING_NAME = re.compile(
    r"^(_+|mem(cpy|set|move)|str(len|cpy|cat|chr|dup)|malloc|free|realloc|"
    r"printf|puts|vprintf|snprintf|__|lock_|xQueue|xTask|pvPort|vTask|nvs_|"
    r"esp_|spi_flash|lwip|tcp_|udp_|ble_|gatt|hci_)", re.I)


def load_found_tokens():
    """Notable strings the rest of the toolkit already surfaced - the ones a
    real check is likely to reference. Kept high-precision on purpose."""
    tokens = set()
    lj = os.path.join(WORK, "meta", "leads.json")
    if os.path.isfile(lj):
        try:
            data = json.load(open(lj))
        except (ValueError, OSError):
            data = {}
        # Buckets whose members are specific enough to be worth matching on.
        keep = ("flag-format", "credential", "hash", "jwt",
                "base64", "base32", "bacon-cipher", "url/host")
        for b in keep:
            for t in data.get("buckets", {}).get(b, []):
                t = t.strip()
                if len(t) >= 4:
                    tokens.add(t)
    return tokens


def split_functions(text):
    """Yield (name, body) per function in a Ghidra decompiled.c.

    ExportArtifacts prints each function's C then a blank line; a function ends
    at a column-0 '}' (nested blocks close with an indented '}'). The file's
    header comment attaches to the first block, which is harmless."""
    cur = []
    for line in text.splitlines():
        cur.append(line)
        if line == "}":                      # column-0 close = end of a function
            block = "\n".join(cur)
            cur = []
            name = func_name(block)
            if name:
                yield name, block
    # any trailing lines without a closing brace are preamble/failed decompiles


def func_name(block):
    """The defined function's name: the identifier before '(' on the signature
    line (column 0, not a comment/brace)."""
    for line in block.splitlines():
        if not line or line[0] in " \t/*{}":
            continue
        if "(" in line:
            ids = re.findall(r"[A-Za-z_]\w*", line.split("(")[0])
            if ids:
                return ids[-1]
    return None


def load_functions_meta(path):
    """name -> (addr, size) from functions.txt: '<addr>  <name>  <n> bytes'."""
    meta = {}
    if not os.path.isfile(path):
        return meta
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^(\S+)\s+(\S+)\s+(\d+)\s+bytes", line)
        if m:
            meta[m.group(2)] = (m.group(1), int(m.group(3)))
    return meta


def score_function(name, body, found):
    """Return (score, [reasons]) for one function body."""
    score = 0
    reasons = []

    # 1. References something the toolkit already flagged (strongest signal).
    hits = [t for t in found if t in body]
    if hits:
        for t in hits[:3]:
            score += 5
            reasons.append("references found lead %r" % (t[:48]))
        if len(hits) > 3:
            reasons.append("...and %d more found leads" % (len(hits) - 3))

    # 2. Comparison primitives - an equality check against a secret. If the
    #    comparison is against a string literal, that literal is the answer.
    cmps = sorted(set(CMP.findall(body)))
    if cmps:
        score += 3
        reasons.append("comparison: " + ", ".join(cmps))
        operands = []
        for m in CMP_LITERAL.findall(body):
            if m not in operands:
                operands.append(m)
        if operands:
            score += 2
            reasons.append("compares against: " + ", ".join('"%s"' % o[:48] for o in operands[:4]))

    # 2b. Strings the function assembles at runtime (packed into wide hex
    #     constants) - exactly the ones `strings` and fw-hunt never see.
    assembled = []
    for h in PACKED_HEX.findall(body):
        txt = decode_packed(h)
        if txt and txt not in assembled:
            assembled.append(txt)
    if assembled:
        score += 4
        reasons.append("assembles string(s): " + ", ".join("%r" % a for a in assembled[:5]))

    # 3. Challenge-flavoured keywords in string literals.
    kws = sorted({k.lower() for k in KEYWORD.findall(body)})
    if kws:
        score += 3
        reasons.append("keywords: " + ", ".join(kws[:6]))

    # 4. XOR / bit-twiddling density - custom cipher or checksum.
    xor = body.count(" ^ ") + body.count("^=")
    if xor >= 3:
        score += 3
        reasons.append("XOR-heavy (%d) - possible cipher/checksum" % xor)
    elif xor >= 1:
        score += 1
    shifts = body.count(" << ") + body.count(" >> ")
    if shifts >= 4:
        score += 1
        reasons.append("bit-twiddling (%d shifts)" % shifts)

    # 5. Crypto / encoding constants.
    if CRYPTO_CONST.search(body):
        score += 4
        reasons.append("crypto/CRC init constant")
    if B64_ALPHABET in body or B64_ALPHABET[:38] in body:
        score += 3
        reasons.append("base64 alphabet present")
    if B32_ALPHABET in body:
        score += 3
        reasons.append("base32 alphabet present")

    # A well-known SDK/libc name with no other signal is almost never a lead.
    if reasons and BORING_NAME.match(name) and score <= 3:
        return 0, []
    return score, reasons


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORK, "reports", "ghidra")
    dec = os.path.join(out_dir, "decompiled.c")
    if not os.path.isfile(dec):
        print("[x] no decompiled.c in %s - run headless analysis ([33]/[36]) first."
              % out_dir, file=sys.stderr)
        return 1

    found = load_found_tokens()
    fmeta = load_functions_meta(os.path.join(out_dir, "functions.txt"))
    text = open(dec, encoding="utf-8", errors="replace").read()

    total = 0
    leads = []
    for name, body in split_functions(text):
        total += 1
        score, reasons = score_function(name, body, found)
        if score > 0:
            addr, size = fmeta.get(name, ("", 0))
            leads.append({"name": name, "addr": addr, "size": size,
                          "score": score, "reasons": reasons})

    leads.sort(key=lambda d: (-d["score"], -d["size"]))

    rel = os.path.relpath(out_dir, WORK) if out_dir.startswith(WORK) else out_dir
    head = [
        "# code leads - %s/decompiled.c" % rel,
        "# %d functions scanned, %d flagged%s" % (
            total, len(leads),
            " (cross-referenced %d found leads)" % len(found) if found else
            " (no meta/leads.json - static heuristics only)"),
        "# ranked most-relevant first; the reason follows each. Read from the top.",
        "",
    ]
    body_lines = []
    for i, d in enumerate(leads, 1):
        loc = ("%s  " % d["addr"]) if d["addr"] else ""
        sz = ("  %d bytes" % d["size"]) if d["size"] else ""
        body_lines.append("%3d. [%2d] %s%s%s" % (i, d["score"], loc, d["name"], sz))
        for r in d["reasons"]:
            body_lines.append("        - %s" % r)
    if not leads:
        body_lines.append("(nothing scored above zero - try [34] the GUI, or widen the heuristics.)")

    report = "\n".join(head + body_lines) + "\n"

    with open(os.path.join(out_dir, "code-leads.txt"), "w", encoding="utf-8") as fh:
        fh.write(report)
    with open(os.path.join(out_dir, "code-leads.json"), "w", encoding="utf-8") as fh:
        json.dump({"dir": rel, "scanned": total, "found_tokens": len(found),
                   "leads": leads}, fh, indent=2)

    # Print the header and the top of the list (the file keeps all of it).
    print("\n".join(head), end="")
    for line in body_lines[:60]:
        print(line)
    if len(body_lines) > 60:
        print("    ... see %s/code-leads.txt for the full ranked list" % rel)
    print("[+] wrote %s/code-leads.txt (%d leads)" % (rel, len(leads)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
