terraform {
  required_version = ">= 1.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# Auth via CLOUDFLARE_API_TOKEN env var (set in CI / locally from 1P).
provider "cloudflare" {}
