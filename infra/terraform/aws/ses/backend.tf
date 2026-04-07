# Backend configuration for ses module

terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/ses/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
