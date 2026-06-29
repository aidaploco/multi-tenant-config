terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 7.0"
    }
  }

  # FIRST RUN: leave this commented and apply with local state (there is no bucket yet).
  # AFTER the first apply has created the bucket, uncomment, fill in the name this root
  # printed as `state_bucket_name`, and run `terraform init -migrate-state`.
  #
  # backend "gcs" {
  #   bucket = "REPLACE-with-output.state_bucket_name"
  #   prefix = "bootstrap"
  # }
}

# Phase 0 runs as a human with Org-Admin via Application Default Credentials — no impersonation,
# because the identities that CI later impersonates do not exist until this root creates them.
provider "google" {
  region = var.region
}
