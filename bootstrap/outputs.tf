# These outputs are the handoff from Phase 0 to everything else: the CI workflows reference the
# WIF provider and the two SA emails; the deploy roots reference the folder IDs and state bucket.

output "state_bucket_name" {
  description = "Name of the Terraform state bucket. Put this in the backend block (see versions.tf)."
  value       = google_storage_bucket.tfstate.name
}

output "management_project_id" {
  description = "The management project that holds state and CI identities."
  value       = google_project.management.project_id
}

output "wif_provider_name" {
  description = "Full resource name of the GitHub OIDC provider, for the `google-github-actions/auth` step."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "planner_service_account" {
  description = "Read-only CI identity, impersonated by `plan` jobs on any branch."
  value       = google_service_account.planner.email
}

output "applier_service_account" {
  description = "Write CI identity, impersonated by `apply` jobs on main only."
  value       = google_service_account.applier.email
}

output "folder_ids" {
  description = "Folder IDs for the deploy roots: tenant projects go under tenants/, shared runtime under runtime/."
  value = {
    tenants  = google_folder.tenants.id
    runtime  = google_folder.runtime.id
    platform = google_folder.platform.id
  }
}
