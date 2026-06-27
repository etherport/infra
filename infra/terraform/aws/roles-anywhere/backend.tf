# Backend configuration for roles-anywhere module (M71)

terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/roles-anywhere/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
