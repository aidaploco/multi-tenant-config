# The most important security control in Phase 0 (ADR-0001 D12): TWO CI identities, not one.
#
#   planner — READ-ONLY. Assumable from ANY pull-request branch. Runs `terraform plan`.
#   applier — WRITE.     Assumable ONLY from refs/heads/main. Runs `terraform apply`.
#
# Why: a pull request can contain untrusted code (provider plugins, data sources) that executes
# during `plan`. If `plan` ran as a powerful identity, a malicious PR could abuse it. So the PR
# path can only ever LOOK; the powerful identity is unreachable except from already-merged,
# already-reviewed main. The split is enforced by the WIF `member` conditions below, not by
# convention.

locals {
  pool_name = google_iam_workload_identity_pool.github.name
}

# --- planner: read-only ---
resource "google_service_account" "planner" {
  project      = google_project.management.project_id
  account_id   = "ci-planner"
  display_name = "CI planner (read-only, any PR branch)"
}

# Read-only at the org root: it can SEE everything to produce an accurate plan, change nothing.
resource "google_organization_iam_member" "planner_viewer" {
  org_id = var.org_id
  role   = "roles/viewer"
  member = "serviceAccount:${google_service_account.planner.email}"
}

# Any workflow run from our repo (any ref, incl. PR branches) may impersonate the planner.
resource "google_service_account_iam_member" "planner_wif" {
  service_account_id = google_service_account.planner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_name}/attribute.repository/${local.github_repository}"
}

# --- applier: write ---
resource "google_service_account" "applier" {
  project      = google_project.management.project_id
  account_id   = "ci-applier"
  display_name = "CI applier (write, main branch only)"
}

# Project-management power, granted per managed folder ONLY (never at the org root). The applier
# cannot touch org policies or create folders — those stay human-only (the D12 correction).
resource "google_folder_iam_member" "applier_roles" {
  for_each = {
    for pair in setproduct(keys(local.ci_managed_folders), local.applier_folder_roles) :
    "${pair[0]}:${pair[1]}" => { folder = local.ci_managed_folders[pair[0]], role = pair[1] }
  }
  folder = each.value.folder
  role   = each.value.role
  member = "serviceAccount:${google_service_account.applier.email}"
}

# The applier must associate new projects with the billing account; that right lives on the
# billing account itself, not a folder.
resource "google_billing_account_iam_member" "applier_billing" {
  billing_account_id = var.billing_account
  role               = "roles/billing.user"
  member             = "serviceAccount:${google_service_account.applier.email}"
}

# ONLY workflows running from refs/heads/main may impersonate the applier. The provider's
# attribute_condition already restricts the pool to our repo, so conditioning on ref here yields
# "our repo AND main branch" — untrusted PR branches are excluded.
resource "google_service_account_iam_member" "applier_wif" {
  service_account_id = google_service_account.applier.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_name}/attribute.ref/refs/heads/main"
}
