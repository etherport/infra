terraform {
  required_version = ">= 1.14"

  required_providers {
    unifi = {
      # M125 (2026-07-02): migrated to the maintained community fork via a FULL
      # schema rewrite + state-rm/import session (replace-provider is unsafe across
      # this fork's rewritten schemas — see docs/planning/outstanding-work.md M125).
      source  = "ubiquiti-community/unifi"
      version = "0.55.0"
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
