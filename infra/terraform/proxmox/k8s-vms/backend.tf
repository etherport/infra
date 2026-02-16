terraform {
  backend "s3" {
    # S3 bucket for state storage
    bucket = "terraform.wind.etherport.net"
    key    = "proxmox/k8s-vms/terraform.tfstate"
    region = "us-west-2"

    # DynamoDB table for state locking
    use_lockfile   = true
    dynamodb_table = "homelab-terraform-locks"

    # Encryption
    encrypt = true

    # AWS credentials profile
    profile = "homelab"
  }
}
