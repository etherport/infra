# Provider configuration for s3 module

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = "us-west-2"
  profile = "homelab"

  default_tags {
    tags = {
      Environment = "homelab"
      ManagedBy   = "terraform"
      Module      = "s3"
    }
  }
}
