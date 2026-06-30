terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 7.0"
    }
  }

  # Separate state from the tenant root. CI passes -backend-config bucket + prefix=runtime/<env>.
  backend "gcs" {}
}
