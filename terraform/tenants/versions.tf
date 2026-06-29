terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 7.0"
    }
  }

  # Remote state lives in the bootstrap-created bucket. Partial config: CI passes
  # `-backend-config="bucket=..."` and `-backend-config="prefix=tenants/<env>"` at init,
  # so each environment gets its own state object. Local `terraform test` uses
  # `init -backend=false` and is unaffected.
  backend "gcs" {}
}
