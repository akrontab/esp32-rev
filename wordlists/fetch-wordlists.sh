#!/usr/bin/env bash
# Fetch the bigger wordlists into this directory on demand. They are NOT
# committed (see .gitignore) - same policy as firmware dumps: large, and no
# reason to live in git.
#
# rockyou + OneRuleToRuleThemAll are already baked into the hashcat image, so
# you do not need this for a first pass. Use it when local rockyou+rules has
# missed and you want broader coverage before escalating to the Linode rig
# (where cloud-init fetches the multi-GB lists directly).
#
#   ./fetch-wordlists.sh            # the sensible default set
#   ./fetch-wordlists.sh seclists   # add SecLists password lists
#   ./fetch-wordlists.sh weakpass   # add weakpass (large, ~muti-GB)

set -euo pipefail
cd "$(dirname "$0")"

get() {  # url dest
  local url="$1" dest="$2"
  if [ -f "$dest" ]; then echo "[=] $dest already present"; return; fi
  echo "[*] fetching $dest"
  curl -fSL --retry 3 -o "$dest" "$url"
  echo "[+] $dest  ($(wc -l < "$dest" 2>/dev/null || echo '?') lines)"
}

set_default() {
  # SecLists' most useful password lists - high value, manageable size.
  get "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10-million-password-list-top-1000000.txt" \
      "top1M.txt"
  get "https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/darkweb2017-top10000.txt" \
      "darkweb-top10k.txt"
  echo "[i] rockyou + OneRule are already in the hashcat image; these supplement it."
}

set_seclists() {
  echo "[*] SecLists is large; cloning only the Passwords subset via sparse checkout"
  if [ ! -d SecLists ]; then
    git clone --filter=blob:none --sparse https://github.com/danielmiessler/SecLists.git
    ( cd SecLists && git sparse-checkout set Passwords )
  fi
  echo "[+] SecLists/Passwords available"
}

set_weakpass() {
  echo "[!] weakpass is multi-GB - prefer fetching this on the Linode rig, not the laptop."
  get "https://download.weakpass.com/wordlists/1948/weakpass_3a.7z" "weakpass_3a.7z" || \
    echo "[!] weakpass URL may have changed; check https://weakpass.com/wordlists"
}

case "${1:-default}" in
  default)  set_default ;;
  seclists) set_seclists ;;
  weakpass) set_weakpass ;;
  *) echo "usage: $0 [default|seclists|weakpass]"; exit 2 ;;
esac

echo
echo "[i] These are mounted into the hashcat container at /opt/wordlists/extra"
echo "    when you run local cracking. Reference them there, e.g.:"
echo "      hashcat -m 100 hashes.txt /opt/wordlists/extra/top1M.txt -r \$HASHCAT_RULES_DIR/best64.rule"
