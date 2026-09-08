# Hash cracking

Badge challenges often reduce to a hash to crack (the 2025 badge's "Crack the
Hash" gave two SHA-1 values over BLE). The strategy is **local first, cloud
only as a deliberate escalation.**

---

## The rule

1. **Identify** the hash. Strategy depends entirely on the algorithm.
2. **Crack locally** on the RTX 3060 (Docker + GPU). Fast unsalted hashes fall
   in seconds to minutes.
3. **Escalate to the Linode rig only if local finds nothing in ~30 minutes** —
   i.e. a slow algorithm, a big brute-force keyspace, or a long unattended run.
   You spin the rig up by hand with Terraform, and tear it down when done.

Why the split: your laptop GPU cracks fast hashes of dictionary words instantly
(the 2025 badge's SHA-1 pair cracked in **27 seconds** — `accessit` and
`darkimage`). Cloud GPUs bill hourly and a forgotten instance is the expensive
mistake. The cloud is for the genuinely hard cases, not the common ones.

---

## Step 1 — identify  (menu `[29]`)

`[29]` scans the workspace (strings, NVS, BLE values, extracted files) for
hash-shaped tokens and maps each to candidate hashcat modes.

The critical point: **length is ambiguous.** 40 hex is SHA-1 (`-m 100`) *or*
RIPEMD-160 (`-m 6000`); 32 hex is MD5 *or* NTLM *or* MD4. `hash-id` shows the
ranked candidates; pick the mode that fits the context (NTLM from a Windows
dump, SHA-1 from a web app, etc.).

Results: `reports/hashes-found.txt`.

---

## Step 2 — crack locally  (menu `[30]`)

Put your hashes (all the **same** type) one-per-line in
`workspace/<target>/reports/`, then run `[30]`, give it the hashcat mode, and
optionally let it also try a wordlist built from the badge's own strings.

It runs an escalating sequence, stopping when everything cracks:

1. rockyou straight
2. rockyou + `best64` rules (fast, high yield)
3. rockyou + `OneRuleToRuleThemAll` (slower, much broader)
4. target-derived wordlist + rules (with `--custom`)

Results land in `reports/cracked.txt` and a reusable `reports/cracked.potfile`.

Runs in the `esp32-re/hashcat` image on the local GPU (`--gpus all`,
`NVIDIA_DRIVER_CAPABILITIES=all`). rockyou + `OneRuleToRuleThemAll` are baked
in, so it works offline at a venue.

### Wordlists

See [../wordlists/README.md](../wordlists/README.md). Short version: rockyou +
rules are in the image; bigger lists are fetched on demand into the gitignored
`wordlists/` dir and mounted at `/opt/wordlists/extra`; the best list is often
one built from the badge itself (`--custom`).

---

## Step 3 — escalate to the Linode rig  (only when needed, by hand)

You run every step here yourself — the control plane never touches your cloud
account or spends money.

### One-time

- A Linode API token: `export TF_VAR_linode_token=...`
- `cd linode && terraform init`
- `cp terraform.tfvars.example terraform.tfvars` and set a GPU-capable region
  and, ideally, `allowed_ssh_cidr` to your IP/32. Verify the plan id:
  `linode-cli linodes types --json | jq -r '.[].id' | grep gpu`

### Each run

```bash
cd linode
terraform apply                      # provisions a GPU box; cloud-init installs
                                     # driver + CUDA + hashcat + wordlists
terraform output readiness           # prints a command that waits for /root/READY
                                     # and shows nvidia-smi

# push the hashes and crack, inside tmux so a dropped session survives:
scp -i id_esp32crack ../workspace/<target>/reports/hashes.txt root@<ip>:/root/
ssh -i id_esp32crack root@<ip>
  tmux new -s crack
  ./crack.sh -m 100 /root/hashes.txt          # dictionary+rules, or:
  hashcat -m 100 -O -w 4 /root/hashes.txt -a 3 '?l?l?l?l?l?l?l?l'   # 8-char mask

terraform destroy                    # <-- ALWAYS. GPU instances bill hourly.
```

Terraform generates the SSH keypair (`linode/id_esp32crack`, gitignored) on
apply, so there is no key to pre-provision. `hashcat --restore` resumes an
interrupted long run.

### Cost

A single RTX 4000 Ada is ~$0.52/hr — a full weekend is ~$31. The discipline
that keeps it cheap is `terraform destroy` the moment the run finishes; do not
leave a GPU idle-billing.

> **Validation note.** The local path is validated end-to-end on real hardware
> (both badge hashes cracked via the menu). The Terraform rig is written and
> `terraform validate`-clean, but has **not** been applied against a live paid
> GPU instance — treat the first `apply` as a shakeout and watch
> `/var/log/cloud-init-output.log`. The NVIDIA driver step is the most likely
> thing to need a tweak for whatever GPU/kernel Linode provisions.

---

## What leaves your machine

Only the hash file (tiny). Hashes are one-way and, from a public badge, not
sensitive — but the principle holds: never paste them into random web crackers,
and lock the rig's SSH to your own IP.
