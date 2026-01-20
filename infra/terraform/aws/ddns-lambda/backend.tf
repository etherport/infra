terraform {
  backend "s3" {
    bucket         = "terraform.wind.etherport.net"
    key            = "aws/ddns-lambda/terraform.tfstate"
    region         = "us-west-2"
    use_lockfile   = true
    dynamodb_table = "homelab-terraform-locks"
    encrypt        = true
    profile        = "homelab"
  }
}
