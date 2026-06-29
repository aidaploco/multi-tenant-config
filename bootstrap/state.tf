# The management project: home of the Terraform state and the CI identities. It lives under the
# platform/ folder and is marked PREVENT so it cannot be deleted by an errant apply.
resource "google_project" "management" {
  name            = "platform-management"
  project_id      = var.management_project_id
  folder_id       = google_folder.platform.id
  billing_account = var.billing_account
  labels          = local.labels
  deletion_policy = "PREVENT"
}

# APIs the management project itself needs.
resource "google_project_service" "management" {
  for_each = toset([
    "cloudkms.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "orgpolicy.googleapis.com",
  ])
  project            = google_project.management.project_id
  service            = each.value
  disable_on_destroy = false
}

# A bootstrap keyring + key so the state bucket is CMEK-encrypted like everything else (D6).
# State is sensitive (it holds resource attributes); it does not get Google-managed keys.
resource "google_kms_key_ring" "bootstrap" {
  name     = "bootstrap-keyring"
  project  = google_project.management.project_id
  location = var.region

  depends_on = [google_project_service.management]
}

resource "google_kms_crypto_key" "tfstate" {
  name            = "tfstate-key"
  key_ring        = google_kms_key_ring.bootstrap.id
  rotation_period = "7776000s" # 90 days — native rotation, OPA requires this to be set.
  labels          = local.labels

  lifecycle {
    prevent_destroy = true
  }
}

# The GCS service agent must be allowed to use the key, or bucket creation fails.
data "google_storage_project_service_account" "gcs" {
  project = google_project.management.project_id
}

resource "google_kms_crypto_key_iam_member" "gcs_uses_key" {
  crypto_key_id = google_kms_crypto_key.tfstate.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# The state bucket: versioned (so we can recover a clobbered state), CMEK-encrypted, uniform
# access, public access hard-blocked. Same fail-closed posture every tenant bucket gets.
resource "google_storage_bucket" "tfstate" {
  name     = local.state_bucket_name
  project  = google_project.management.project_id
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.tfstate.id
  }

  labels = local.labels

  depends_on = [google_kms_crypto_key_iam_member.gcs_uses_key]
}
