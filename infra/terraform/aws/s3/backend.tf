# Backend configuration for s3 module

terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/s3/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
