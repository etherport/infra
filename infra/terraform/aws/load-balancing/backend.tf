# Terraform backend configuration for load-balancing module

terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/load-balancing/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
