# Provider configuration for the config stack.
#
# AWS Config is REGIONAL: a recorder must exist in every region you want covered.
# We run BOTH active regions (us-west-2 primary + us-east-1 for ACM/CloudFront/
# alexa) from one stack. us-west-2 is the DEFAULT provider, so the account-wide
# singletons (S3 bucket + IAM service role + aggregator) + global resource types
# (IAM, CloudFront, etc.) land there; us-east-1 is the `use1` alias for its
# regional recorder only (global types recorded in us-west-2 ONLY -> no double-bill).

terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = "us-west-2"
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = "homelab"
      ManagedBy   = "terraform"
      Module      = "config"
      Purpose     = "config-recorder"
    }
  }
}

provider "aws" {
  alias   = "use1"
  region  = "us-east-1"
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Environment = "homelab"
      ManagedBy   = "terraform"
      Module      = "config"
      Purpose     = "config-recorder"
    }
  }
}
