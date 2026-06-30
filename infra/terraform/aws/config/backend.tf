# Backend configuration for the config (AWS Config recorder) stack.

terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/config/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
