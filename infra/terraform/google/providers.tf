terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# google provider — uses Application Default Credentials.
# For local apply: `gcloud auth application-default login`
# For CI: set GOOGLE_APPLICATION_CREDENTIALS to a service-account JSON OR
# pass via `google_credentials` variable; OR use workload-identity-federation
# from the github-runner.
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

variable "gcp_project_id" {
  description = "GCP project ID (e.g., cloudflare-zero-trust). Pre-exists (created in console)."
  type        = string
}

variable "gcp_region" {
  description = "Default GCP region for resources"
  type        = string
  default     = "us-west2"
}
