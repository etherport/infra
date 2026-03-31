# Terraform backend configuration
# State stored in S3

terraform {
  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws/external-monitoring/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
    profile      = "homelab"
  }
}
