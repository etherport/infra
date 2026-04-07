# Backend configuration for route53 module

terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/route53/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
