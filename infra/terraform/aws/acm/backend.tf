# Backend configuration for acm module

terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/acm/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
