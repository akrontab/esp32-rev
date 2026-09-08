# Wordlists

Big wordlists are **not committed** (see `.gitignore`) — they are large and, like
firmware dumps, have no reason to live in git. This dir holds them at runtime;
only this README and `fetch-wordlists.sh` are tracked.

## What's already in the hashcat image (no fetch needed)

- **rockyou.txt** — ~14M real leaked passwords. The universal first pass.
- **OneRuleToRuleThemAll.rule** — the best general-purpose rule set.
- hashcat's own rules (`best64`, `dive`, …) at `$HASHCAT_RULES_DIR`.

`rockyou + best64` then `rockyou + OneRule` is what the control plane's local
crack runs by default, and it covers the large majority of human-chosen
passwords in minutes on the RTX 3060.

## When to fetch more

Only after the baked-in lists miss. `./fetch-wordlists.sh` pulls a sensible
supplement (SecLists top-1M, darkweb top-10k). `seclists` and `weakpass`
arguments pull larger sets — but multi-GB lists belong on the **Linode rig**
(its cloud-init fetches them), not the laptop.

## The highest-value list is often the one you build

For a themed badge, a wordlist derived from the badge itself beats a generic
giant list. The local crack's `--custom` option auto-builds one from the
target's `reports/strings.txt` and extracted files. Add event names, sponsors,
speakers, and in-jokes by hand — those are exactly what badge authors pick.

## How these reach the cracker

Files here are mounted read-only into the hashcat container at
`/opt/wordlists/extra`. Reference them there:

```
hashcat -m 100 /work/reports/hashes.txt /opt/wordlists/extra/top1M.txt \
        -r $HASHCAT_RULES_DIR/best64.rule
```

## Wordlist reference

| List | Size | Notes |
|---|---|---|
| rockyou | 133 MB | baked in; always first |
| SecLists/Passwords | ~1 GB | themed + leaked-DB lists; sparse-clone |
| top1M / darkweb-top10k | small | high-value supplements |
| weakpass | multi-GB | rig only |
| crackstation | 15–90 GB | rig only, deep coverage |
