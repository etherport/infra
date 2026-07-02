terraform {
  required_version = ">= 1.14"

  required_providers {
    unifi = {
      # M125 (2026-07-02): migrated paultyng/unifi (ARCHIVED 2026-04-30; it
      # deterministically 400s PUT networkconf for 3 of 7 networks — bit the M110
      # dhcp_dns cutover) → the community fork, which continues the 0.41.x lineage
      # as a drop-in. The provider ADDRESS change requires a one-time
      # `terraform state replace-provider` (done in terraform-unifi.yml, idempotent).
      # AVOID the filipowm fork (rebased to v1.0.0 with schema changes).
      source  = "ubiquiti-community/unifi"
      version = "0.54.0"
    }
  }
}

provider "unifi" {
  username       = var.unifi_username
  password       = var.unifi_password
  api_url        = var.unifi_api_url
  site           = var.unifi_site
  allow_insecure = var.unifi_allow_insecure
}
