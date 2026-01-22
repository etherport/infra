terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/snapshot-archive/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
