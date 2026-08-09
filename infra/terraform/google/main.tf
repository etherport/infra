// Google Cloud Platform IaC — record of the homelab's GCP estate.
//
// After the 2026-06-03 audit the account holds exactly TWO projects, both
// credential/OAuth-only (no billable compute/storage anywhere). This module
// codifies both so there is a record everywhere; the OAuth clients + consent
// screens they hold are NOT Terraform-manageable (see README "Manual setup")
// and are documented there for replication instead.
//
// SCOPE — what Terraform CAN manage here: the projects themselves (pre-created
// in console, imported into state) and API enablements. What it CANNOT manage
// (Google API doesn't expose them): OAuth consent screens, OAuth 2.0 Client
// IDs/Secrets, and the Nest Device Access Console project. Those are in the
// README runbooks.

// ===========================================================================
// Project 1 — Cloudflare Zero Trust SSO   (homelab-infra-497414)
// ===========================================================================
// Holds the OAuth 2.0 Client that Cloudflare Access uses as its Google SSO
// IdP. Client ID 909531984469-evt1p0dn5h3v1op7vllntc5b5iob1k7q (the
// 909531984469 prefix == this project's number). Secret lives in 1Password
// ("Cloudflare Zero Trust Google IdP") + Cloudflare, never in git.
//
// project_id comes from the GCP_PROJECT_ID CI secret (= homelab-infra-497414).
// `name` matches the live display name; changing it here RENAMES the project
// on apply (the lever if you ever want a more descriptive title).
resource "google_project" "cloudflare_zero_trust" {
  project_id = var.gcp_project_id
  name       = "homelab-infra"
  // Billing account attached to the live project — declared so TF does NOT
  // detach it (omitting this makes TF plan billing_account -> null). The
  // project is OAuth-only/no billable usage, but keeping billing as-is is the
  // zero-change choice; detaching is a separate, deliberate decision.
  billing_account = "0169E4-61F6AE-AFE6C8"

  // Destroying this project would delete the OAuth credentials CF Access SSO
  // depends on. Never let TF do that.
  lifecycle {
    prevent_destroy = true
  }
}

// --- API enablements on this project ----------------------------------------
// The CF-Access OAuth IdP itself needs no extra API. These are for the Cue
// "Find food" feature (etherport/cue), which calls Places API (New)
// server-side for nearby-restaurant search.
//
// ⚠️ SERVICE ID: Places API (New) is `places.googleapis.com` (its endpoints are
// https://places.googleapis.com/v1/...). `places-backend.googleapis.com` is the
// LEGACY "Places API" — NOT this. The key restriction below must match the
// endpoint the app actually calls, i.e. places.googleapis.com.
locals {
  cue_places_apis = [
    "apikeys.googleapis.com", // lets Terraform create/manage google_apikeys_key
    "places.googleapis.com",  // Places API (New) — Cue Find-food nearby search
  ]
}

resource "google_project_service" "cloudflare_zero_trust" {
  for_each = toset(local.cue_places_apis)

  project = google_project.cloudflare_zero_trust.project_id
  service = each.key

  // Leave the API enabled if this resource is removed (matches the ha_nest style).
  disable_on_destroy         = false
  disable_dependent_services = false
}

// Restricted API key for Cue Find-food. The app calls Google SERVER-SIDE, so an
// API restriction is the right (and only) scope — NO browser/referrer restriction.
// No IP restriction for now: the cluster egresses via the homelab's dynamic WAN IP
// (DDNS), so there's no stable source IP to pin (revisit if a static egress lands).
// The secret material (.key_string) is delivered to the cue-app SOPS secret out of
// band (see outputs.tf + the cue-api README) — Terraform never writes the k8s secret.
resource "google_apikeys_key" "cue_places" {
  name         = "cue-places-find-food"
  display_name = "Cue Find-food (Places API New)"
  project      = google_project.cloudflare_zero_trust.project_id

  restrictions {
    api_targets {
      service = "places.googleapis.com"
    }
  }

  // The apikeys API must be live before the key can be created.
  depends_on = [google_project_service.cloudflare_zero_trust]
}

// ===========================================================================
// Project 2 — Home Assistant · Nest (SDM)   (poised-lens-448222-d2)
// ===========================================================================
// Home Assistant ↔ Google Nest via the Smart Device Management API. Holds an
// OAuth 2.0 Client + is linked to a Device Access Console project ($5 fee,
// already paid). Billing is DISABLED on this project (Nest usage sits in the
// free tier) — intentional, do not enable. Kept standalone (see README:
// consolidating into homelab-infra buys nothing and risks a Nest outage).
resource "google_project" "home_assistant_nest" {
  project_id = "poised-lens-448222-d2"
  name       = "Home Assistant - Nest SDM"

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  // The two non-default APIs Nest actually requires. Both already enabled.
  ha_nest_apis = [
    "smartdevicemanagement.googleapis.com", // Nest device read/control
    "pubsub.googleapis.com",                // Nest device-event stream → HA
  ]
}

resource "google_project_service" "ha_nest" {
  for_each = toset(local.ha_nest_apis)

  project = google_project.home_assistant_nest.project_id
  service = each.key

  // Don't disable the API if this resource is removed — Nest would break.
  disable_on_destroy         = false
  disable_dependent_services = false
}
