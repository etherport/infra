terraform {
  required_version = ">= 1.14"

  required_providers {
    unifi = {
      source = "paultyng/unifi"
      # Pin to a known-good version. UniFi Network 10.3.58 is newer than
      # what most provider versions explicitly test against, but Phase 1
      # resources (unifi_network, unifi_port_forward, unifi_user) have
      # stable schemas going back to v0.30+.
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
