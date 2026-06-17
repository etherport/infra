# Variables for compute module

variable "aws_profile" {
  description = "AWS profile to use (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "gs_ec2_public_key" {
  description = "Public key for GS-EC2 key pair"
  type        = string
  sensitive   = true
  # This will be populated during import - key pairs don't expose public key after creation
  # Set to empty string for import, actual key not needed for existing resources
  default = ""
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
  default     = "graham.m.smith@me.com"
}

# gh-runner automation pubkey appended to ubuntu's authorized_keys via cloud-init
# (first-boot only; both aws_instance blocks ignore_changes=[user_data]). NOTE:
# this same key is ALSO declared in proxmox/{k8s-vms,standalone-vms}/variables.tf
# and infra/ansible/playbooks/pve-sshd.yml — true cross-stack dedup isn't possible
# from a single TF var. If rotated, update all of them (see
# memory/reference_pve_automation_pubkey.md for the canonical placement list).
variable "automation_ssh_pubkey" {
  description = "gh-runner automation SSH public key for ubuntu cloud-init authorized_keys"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDbuFR+hru9VgMct+C7pCxrxXB0O3mrhFcBP3QJ/D8IR automation@homelab"
}

# Networking IDs from the aws/networking stack (separate state). Kept as
# variables-with-defaults rather than a terraform_remote_state lookup to avoid
# cross-stack coupling; defaults match the live resource IDs (zero plan-diff).
variable "vpc_id" {
  description = "VPC ID (private_infra) from the aws/networking stack"
  type        = string
  default     = "vpc-0cf7cb3b71fc48958"
}

variable "public_subnet_id" {
  description = "Public subnet ID (public1) from the aws/networking stack"
  type        = string
  default     = "subnet-05df0a901053021dd"
}

variable "sg_vpn_server_id" {
  description = "Security group ID for the VPN server"
  type        = string
  default     = "sg-08323ff8e98ecb563"
}

variable "sg_dns_server_id" {
  description = "Security group ID for the DNS server"
  type        = string
  default     = "sg-08d12e417159c18d2"
}

variable "sg_internal_comms_id" {
  description = "Security group ID for internal inter-instance comms"
  type        = string
  default     = "sg-0c882ffea5692bd63"
}

variable "sg_allow_ssh_id" {
  description = "Security group ID allowing SSH"
  type        = string
  default     = "sg-0079fee23ee54417a"
}
