locals {
  # The state bucket name defaults to <management-project>-tfstate when not overridden.
  state_bucket_name = coalesce(var.state_bucket_name, "${var.management_project_id}-tfstate")

  # Every platform-owned resource carries the same label discipline tenants do (the OPA policy
  # requires these four keys on projects, buckets, and KMS keys). Platform infra is labelled as
  # tenant "platform" so it is never mistaken for a tenant's footprint.
  labels = {
    tenant              = "platform"
    environment         = "mgmt"
    data_classification = "internal"
    managed-by          = "terraform"
  }

  # The GitHub repository CI runs from, in "owner/name" form, used to scope WIF trust.
  github_repository = "${var.github_org}/${var.github_repo}"

  # Folders CI is allowed to create projects under. The applier gets project-management roles
  # on these and ONLY these; it has no power at the org root.
  ci_managed_folders = {
    tenants = google_folder.tenants.id
    runtime = google_folder.runtime.id
  }

  # Least-privilege role set for the write identity, granted per managed folder. Deliberately
  # excludes anything org-level (no orgpolicy admin, no folder creation) — those stay human-only.
  applier_folder_roles = [
    "roles/resourcemanager.projectCreator",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/storage.admin",
    "roles/cloudkms.admin",
    "roles/logging.admin",
    "roles/monitoring.editor",
  ]
}
