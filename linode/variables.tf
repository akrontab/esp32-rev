variable "linode_token" {
  description = "Linode API token. Set in terraform.tfvars (gitignored); never commit it."
  type        = string
  sensitive   = true
  default     = null
}

variable "gpu_type" {
  description = <<-EOT
    Linode GPU plan. Default is a single RTX 4000 Ada (cheapest GPU plan,
    ~$0.52/hr, plenty for cracking). VERIFY the exact type id for your account
    with:  linode-cli linodes types --json | jq '.[].id' | grep gpu
    Multi-GPU plans (…a2, …a4) scale linearly for deep brute-force.
  EOT
  type        = string
  default     = "g2-gpu-rtx4000a1-s"
}

variable "region" {
  description = <<-EOT
    Region MUST be one that offers GPU plans (not all do). Check:
      linode-cli regions list
    GPU availability is limited to a handful of core regions.
  EOT
  type        = string
  default     = "us-ord"
}

variable "image" {
  description = "Base image. Ubuntu 22.04 supports cloud-init via the Metadata service."
  type        = string
  default     = "linode/ubuntu22.04"
}

variable "label" {
  description = "Instance label (how it shows in the Linode dashboard)."
  type        = string
  default     = "esp32-crack-rig"
}

variable "authorized_keys" {
  description = <<-EOT
    Extra SSH public keys allowed in, ON TOP of the keypair Terraform generates
    for you. Usually leave this empty - apply writes a fresh private key to
    linode/id_esp32crack (gitignored) and authorises its public half. Add your
    own key here only if you also want to log in from an existing key.
  EOT
  type        = list(string)
  default     = []
}

variable "key_path" {
  description = "Where to write the generated private key (0600, gitignored)."
  type        = string
  default     = "id_esp32crack"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach SSH. Lock this to your own IP/32, not the world."
  type        = string
  default     = "0.0.0.0/0"
}

variable "fetch_weakpass" {
  description = "Have cloud-init pull the multi-GB weakpass list on boot (adds minutes)."
  type        = bool
  default     = false
}
