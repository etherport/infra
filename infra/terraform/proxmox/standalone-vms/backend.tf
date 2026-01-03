terraform {
  backend "s3" {
    bucket         = "terraform.wind.etherport.net"
    key            = "proxmox/standalone-vms/terraform.tfstate"
    region         = "us-west-2"
    use_lockfile   = true
    dynamodb_table = "homelab-terraform-locks"
    encrypt        = true
    profile        = "homelab"
  }
}
