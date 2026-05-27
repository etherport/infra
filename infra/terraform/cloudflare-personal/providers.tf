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
provider "cloudflare" {
  # CF API rate limit is 1200 req / 5 min per token; v4 provider fans
  # out parallel reads during refresh. Stretching retries + backoff so
  # transient 429 / auth-throttle storms don't fail the whole plan.
  # Mirrors the cloudflare module — see task #81 for the durable split.
  retries     = 8
  min_backoff = 4
  max_backoff = 120
}
