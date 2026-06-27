# In CI, authentication is keyless: GitHub OIDC -> Workload Identity Federation
# -> the per-environment apply service account (no JSON keys, see ADR-0001 D5/D12).
# Cross-project access uses impersonation of that SA. For local validation,
# Application Default Credentials are used (no apply is run locally).
provider "google" {
  region = var.region
}
