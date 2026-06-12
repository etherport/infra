terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/github-oidc/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
