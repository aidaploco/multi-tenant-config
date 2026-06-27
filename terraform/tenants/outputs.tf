output "selected_tenants" {
  description = "Slugs deployed in this environment (those whose YAML lists it)."
  value       = keys(local.tenants_for_env)
}

output "tenants" {
  description = "Per-tenant deployment summary: project, buckets, and effective compute isolation."
  value = {
    for k, m in module.tenant : k => {
      project_id        = m.project_id
      buckets           = m.bucket_names
      compute_isolation = m.compute_isolation
    }
  }
}
