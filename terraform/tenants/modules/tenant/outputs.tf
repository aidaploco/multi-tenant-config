output "project_id" {
  description = "The tenant's project ID for this environment."
  value       = module.project.project_id
}

output "bucket_names" {
  description = "Map of bucket suffix -> full bucket name (empty if storage layer disabled)."
  value       = { for k, m in module.buckets : k => m.name }
}

output "keyring_id" {
  description = "The tenant's KMS keyring ID."
  value       = module.keys.keyring_id
}

output "compute_isolation" {
  description = "Effective compute isolation (shared|dedicated) after applying the classification default."
  value       = local.compute_isolation
}

output "pinned_versions" {
  description = "Per-layer version pins for this environment (recorded; not yet wired to source refs -- ADR-0002 D2-6)."
  value       = local.layer_versions
}

output "units" {
  description = "Axis-2 scale units declared for this environment (validated; provisioned in a later stage)."
  value = {
    for name, u in local.units : name => {
      type    = try(u.type, null)
      version = try(u.version, null)
      opt_in  = try(u.opt_in, true)
    }
  }
}
