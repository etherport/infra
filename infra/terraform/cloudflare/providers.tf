terraform {
  required_version = ">= 1.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Cloudflare provider — uses CLOUDFLARE_API_TOKEN env var.
# Token scopes required (created at https://dash.cloudflare.com/profile/api-tokens):
#   - Account: Cloudflare Tunnel:Edit
#   - Account: Access: Apps and Policies:Edit
#   - Zone: DNS:Edit (scoped to the wind.etherport.net zone once created,
#     or "All zones from an account" if simpler for now)
#   - Zone: Zone:Read
# Store the token in 1Password as "Cloudflare API (tf)" → field `token`,
# then in the workflow env: CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
provider "cloudflare" {}

# AWS provider — used for Route53 to add the NS delegation record for
# wind.etherport.net under the etherport.net zone. Uses the existing
# `homelab` profile (same pattern as ai-advisor-iam).
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Module    = "cloudflare"
    }
  }
}

variable "aws_profile" {
  description = "AWS profile (empty string = env vars in CI)"
  type        = string
  default     = "homelab"
}

variable "aws_region" {
  description = "AWS region for provider init"
  type        = string
  default     = "us-west-2"
}
