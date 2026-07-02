terraform {
  required_version = ">= 1.14"

  required_providers {
    unifi = {
      # M125 (2026-07-02, attempt 2): paultyng/unifi is ARCHIVED → migrated to the
      # ubiquiti-community fork PINNED TO ITS 0.41.x LINE (0.41.25, the last one) —
      # that line keeps paultyng's resource names, so it IS drop-in. The fork's
      # 0.42+/0.5x re-versioning RENAMED the resource types (attempt 1 with 0.54.0
      # errored "provider does not support resource type unifi_network" AFTER
      # replace-provider had rewritten state — reverted). Moving past 0.41.x later
      # = a deliberate `terraform state mv` migration, not a version bump.
      source  = "ubiquiti-community/unifi"
      version = "0.41.25"
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
