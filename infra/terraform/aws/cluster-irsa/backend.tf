# Backend configuration for cluster-irsa module (M75)

terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/cluster-irsa/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
