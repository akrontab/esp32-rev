output "ip" {
  description = "Public IP of the rig."
  value       = local.public_ip
}

output "ssh" {
  description = "Ready-made SSH command using the generated key."
  value       = "ssh -i ${path.module}/${var.key_path} root@${local.public_ip}"
}

output "push_hashes" {
  description = "Copy a hash file up to the rig."
  value       = "scp -i ${path.module}/${var.key_path} <hashfile> root@${local.public_ip}:/root/"
}

output "readiness" {
  description = "cloud-init drops /root/READY when the toolchain is installed."
  value       = "ssh -i ${path.module}/${var.key_path} root@${local.public_ip} 'cloud-init status --wait; ls -l /root/READY; nvidia-smi'"
}

output "reminder" {
  value = "When the run is done:  terraform destroy   (GPU instances bill hourly)"
}
