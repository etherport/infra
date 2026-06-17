terraform {
  required_version = ">= 1.14"
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
  description = "Cloudflare Zero Trust SSO project ID (homelab-infra-497414). Pre-exists (created in console); supplied via the GCP_PROJECT_ID CI secret / TF_VAR_gcp_project_id locally."
  type        = string
}

variable "gcp_region" {
  description = "Default GCP region for resources"
  type        = string
  default     = "us-west2"
}
