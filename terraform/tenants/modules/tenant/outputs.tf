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
