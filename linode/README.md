# Linode cracking rig (Terraform)

An on-demand GPU box for hash cracking, brought up **by hand** only when local
GPU cracking stalls (see [../docs/hash-cracking.md](../docs/hash-cracking.md)).
The control plane never runs Terraform — you do.

## One-time setup

1. Create a Linode API token with **Linodes** and **Firewalls** read/write
   scope: https://cloud.linode.com/profile/tokens
2. Copy the example and paste your token:
   ```
   cp terraform.tfvars.example terraform.tfvars
   # edit terraform.tfvars: set linode_token = "..."
   ```
   `terraform.tfvars` is gitignored — the token never enters git.
3. Check the plan id and region. No linode-cli needed — the types/regions
   endpoints are public. In PowerShell:
   ```powershell
   # GPU plans (the `id` is the gpu_type string):
   (irm https://api.linode.com/v4/linode/types).data | ? { $_.class -eq 'gpu' } | ft id,label,vcpus,memory
   # regions:
   (irm https://api.linode.com/v4/regions).data | ? { $_.capabilities -contains 'GPU Linodes' } | ft id,label
   ```
   The default `g2-gpu-rtx4000a1-s` (RTX 4000 Ada x1) is the cheapest Ada plan;
   the older `g1-gpu-rtx6000-*` plans are often unavailable. Set `region` /
   `gpu_type` in the tfvars only if the defaults don't fit.
4. `terraform init`

## Validate without spending (do this first)

```
terraform plan
```

`plan` authenticates to the Linode API and checks the token, region and plan
id, and shows exactly what would be created — **without creating anything or
incurring cost.** A clean plan is the real validation that the config works for
your account. This is the safe shakeout.

## Run

```
terraform apply            # creates the GPU box; cloud-init installs the toolchain
terraform output readiness # a command that waits for /root/READY + shows nvidia-smi
```

Push hashes and crack (details in [../docs/hash-cracking.md](../docs/hash-cracking.md)),
then **always**:

```
terraform destroy          # GPU instances bill hourly - do not leave it running
```

## Notes

- Terraform generates the SSH keypair (`id_esp32crack`, gitignored, 0600) on
  apply — no key to pre-provision. `terraform output ssh` prints the exact
  command.
- Lock `allowed_ssh_cidr` to your own IP in the tfvars.
- Gitignored here: `terraform.tfvars`, `*.tfstate*`, `.terraform/`,
  `id_esp32crack`. Only the `*.tf`, `cloud-init.yaml` and `*.example` are tracked.
- **Not yet applied against a live paid GPU** — treat the first `apply` as a
  shakeout and watch `/var/log/cloud-init-output.log` on the box; the NVIDIA
  driver step is the likeliest thing to need a tweak.
