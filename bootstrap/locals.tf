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
    # Project + data plane
    "roles/resourcemanager.projectCreator",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser", # actAs, to attach SAs to GKE/Composer/workloads
    "roles/storage.admin",
    "roles/cloudkms.admin",
    "roles/logging.admin",
    "roles/monitoring.editor",
    # Runtime plane (the shared compute the runtime root builds)
    "roles/compute.networkAdmin",  # VPC, subnets, router, NAT
    "roles/compute.securityAdmin", # firewall rules
    "roles/container.admin",       # GKE Autopilot
    "roles/composer.admin",        # Cloud Composer
    "roles/gkehub.admin",          # Fleet + Config Sync
    "roles/gkehub.gatewayAdmin",   # reach the private cluster API via Connect Gateway (namespaces)
    "roles/secretmanager.admin",   # Config Sync git token
  ]
  # NOTE: these are broad predefined roles — the deliberate place to tighten toward least-privilege
  # (e.g. custom roles) once the resource set is stable. Reviewed by a second human before apply.
}
