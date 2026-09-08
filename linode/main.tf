# The escalation cracking rig. Spun up BY HAND (terraform apply) only when
# local GPU cracking has not returned results in ~30 min, and destroyed as soon
# as the run finishes. GPU plans bill hourly - a forgotten instance is the
# expensive mistake, not the cracking.

# Generate a throwaway SSH keypair for this rig so `apply` is self-contained -
# no need to pre-provision a key. The private key lands in linode/<key_path>
# (gitignored, 0600) and is destroyed with the rig. ed25519: short and fast.
resource "tls_private_key" "rig" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "rig_key" {
  content         = tls_private_key.rig.private_key_openssh
  filename        = "${path.module}/${var.key_path}"
  file_permission = "0600"
}

resource "linode_instance" "crack" {
  label  = var.label
  region = var.region
  type   = var.gpu_type
  image  = var.image
  # Authorise the generated public key, plus any extra keys the user supplied.
  authorized_keys = concat(
    [trimspace(tls_private_key.rig.public_key_openssh)],
    var.authorized_keys,
  )
  # No password login: key auth only. A random one satisfies the API.
  root_pass = random_password.root.result

  # cloud-init: installs the NVIDIA driver + CUDA (for hashcat's nvrtc backend),
  # hashcat, and wordlists, so the box is crack-ready on first boot.
  metadata {
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      fetch_weakpass = var.fetch_weakpass
    }))
  }

  tags = ["esp32-re", "ephemeral", "gpu"]
}

resource "random_password" "root" {
  length  = 32
  special = true
}

locals {
  # ip_address is deprecated; derive the public IP from the ipv4 set. No
  # private IP is attached (private_ip defaults off), so this set is just it.
  public_ip = tolist(linode_instance.crack.ipv4)[0]
}

# Firewall: SSH only, ideally from your IP alone (set allowed_ssh_cidr).
resource "linode_firewall" "crack" {
  label = "${var.label}-fw"

  inbound {
    label    = "allow-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = [var.allowed_ssh_cidr]
  }
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  linodes = [linode_instance.crack.id]
}
