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
#
# Token scopes (created at https://dash.cloudflare.com/profile/api-tokens):
#   - Account: Cloudflare Tunnel: Edit
#   - Account: Access: Apps and Policies: Edit
#   - Account: Access: Service Tokens: Edit  (for Alexa service token)
#   - Zone: DNS: Edit                        (all DNS record management)
#   - Zone: Zone: Edit                       (zone settings post-import)
#
# Zone creation is NOT done via API (Free plan limitation) — zone is added
# manually via dashboard, then imported into TF state. So no "Account: Zone: Edit"
# perm needed.
#
# Store the token in 1Password as "Cloudflare API (tf)" → field `token`.
# Then in GitHub repo secrets:
#   CLOUDFLARE_API_TOKEN  = <the token>
#   CLOUDFLARE_ACCOUNT_ID = <hex account id from dashboard URL>
#   CLOUDFLARE_ZONE_ID    = <hex zone id from CF zone overview → API section>
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
