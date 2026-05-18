terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "proxmox/sdn/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
