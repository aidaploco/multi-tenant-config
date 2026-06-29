# Workload Identity Federation: how CI authenticates with NO downloadable keys (ADR-0001 D5).
# GitHub Actions presents a short-lived OIDC token; GCP exchanges it for a short-lived token of
# one of our service accounts. There is no JSON key anywhere in the chain.

resource "google_iam_workload_identity_pool" "github" {
  project                   = google_project.management.project_id
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  description               = "OIDC trust for platform-config CI (planner + applier)."

  depends_on = [google_project_service.management]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = google_project.management.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  # Map the claims we condition on later: which repo, and which git ref (branch/PR).
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # First line of defence: the pool will only ever mint tokens for OUR repository. Without this,
  # any GitHub repo in the world could attempt to use the pool.
  attribute_condition = "assertion.repository == \"${local.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}
