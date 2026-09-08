terraform {
  required_version = ">= 1.5"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "linode" {
  # Token comes from the LINODE_TOKEN env var (export it; do not commit it),
  # or set it in a gitignored *.tfvars. Never hard-code it here.
  token = var.linode_token
}
