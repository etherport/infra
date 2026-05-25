// Google Cloud Platform IaC scaffold.
//
// SCOPE: only the GCP resources Terraform can actually manage. Notably
// EXCLUDED from this module (Google API doesn't expose them programmatically):
//
//   - OAuth consent screen configuration (App name, support email,
//     test users, publish-to-production flow)
//   - OAuth 2.0 Client IDs (the Client ID + Secret pair that Cloudflare
//     Zero Trust uses for Google SSO IdP)
//
// These remain manual dashboard ops. See README.md "Manual setup" section
// for the procedure. Once we have a Client ID, this module can reference
// it via data sources OR variable inputs, but never CREATE it.
//
// What IS managed here: project itself (assumed pre-created), API
// enablements, IAM bindings for any service accounts we add later.

// Pre-existing project from 2026-05-25 manual setup. Imported into state
// via:
//   terraform import google_project.cloudflare_zero_trust <project-id>
// Once imported, TF detects drift on display_name, billing_account, etc.
resource "google_project" "cloudflare_zero_trust" {
  project_id = var.gcp_project_id
  name       = "Cloudflare Zero Trust"

  // Don't allow accidental TF destroy of the project — that would
  // delete the OAuth credentials we depend on for CF Access SSO.
  lifecycle {
    prevent_destroy = true
  }
}

// APIs the project needs. Adding new resources later usually requires
// adding the corresponding API here first.
//
// Already-enabled (from initial console setup): gmail (default for new
// projects with @gmail.com user). The list below covers what we KNOW
// we need + IAM (for any future SA work).
locals {
  required_apis = [
    "iam.googleapis.com",                   # IAM for SAs
    "iamcredentials.googleapis.com",        # SA token minting
    "cloudresourcemanager.googleapis.com",  # project metadata
    // OAuth IdP needs no extra API enable beyond the default.
  ]
}

resource "google_project_service" "required" {
  for_each = toset(local.required_apis)

  project = google_project.cloudflare_zero_trust.project_id
  service = each.key

  disable_on_destroy         = false
  disable_dependent_services = false
}
