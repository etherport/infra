# AWS US-East-1 Hub Infrastructure
# Providers Configuration

terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }
  }

  backend "s3" {
    bucket       = "terraform.wind.etherport.net"
    key          = "aws-us-east-1/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    profile      = "homelab"
  }
}

#------------------------------------------------------------------------------
# Providers
#------------------------------------------------------------------------------

provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = "homelab"
      ManagedBy   = "terraform"
      Module      = "aws-us-east-1"
    }
  }
}

# Hub provider for VPC peering acceptance
provider "aws" {
  alias   = "hub"
  region  = "us-west-2"
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = "homelab"
      ManagedBy   = "terraform"
    }
  }
}

provider "sops" {}
