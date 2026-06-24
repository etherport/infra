# Provider configuration for cluster-irsa module (M75)

terraform {
  required_version = ">= 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Used to compute the S3 endpoint's TLS root-CA thumbprint for the IAM OIDC
    # provider (required for a self-hosted, non-EKS issuer).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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
      Module      = "cluster-irsa"
      Purpose     = "irsa-workload-identity"
    }
  }
}
