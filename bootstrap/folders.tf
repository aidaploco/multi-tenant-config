# Folders exist ONLY for policy inheritance and tidy grouping, never for isolation — the
# isolation boundary is the per-tenant project (ADR-0001 D2). Three siblings under the org:
#
#   tenants/   — every tenant project (one per tenant per environment) lands here
#   runtime/   — the shared runtime-<env> projects (shared Composer/GKE, D13)
#   platform/  — platform-owned projects: the management project, the central keys project
#
# Day-zero org policies attach at the org root, so all three inherit them automatically.

resource "google_folder" "tenants" {
  display_name = "tenants"
  parent       = "organizations/${var.org_id}"
}

resource "google_folder" "runtime" {
  display_name = "runtime"
  parent       = "organizations/${var.org_id}"
}

resource "google_folder" "platform" {
  display_name = "platform"
  parent       = "organizations/${var.org_id}"
}
