terraform {
  required_version = ">= 1.14"

  required_providers {
    unifi = {
      source = "paultyng/unifi"
      # Archived upstream but still SERVES from the registry and works with our
      # workarounds. M125 (migrate off it) was attempted TWICE on 2026-07-02 and
      # cleanly reverted both times: the ubiquiti-community fork is NOT drop-in at
      # ANY version — 0.54 renamed the resource types, and even its 0.41.25 changed
      # the unifi_network arguments. Migrating = a real schema-diff project
      # (args + possibly state mv), tracked as M125. Don't retry as a version swap.
      version = "~> 0.41"
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
