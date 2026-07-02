output "tenant" {
  description = "The tenant this workspace deploys (ADR-0014)."
  value       = local.slug
}

output "selected_tenants" {
  description = "The deployed tenant (0 or 1 -- one per workspace)."
  value       = keys(local.selected)
}

output "tenants" {
  description = "Per-tenant deployment summary for this workspace."
  value = {
    for k, m in module.tenant : k => {
      project_id        = m.project_id
      buckets           = m.bucket_names
      compute_isolation = m.compute_isolation
    }
  }
}
