output "runtime_project_id" {
  description = "The runtime-<env> project ID."
  value       = module.project.project_id
}

output "network_name" {
  description = "The runtime VPC network name."
  value       = module.vpc.network_name
}

output "subnetwork_name" {
  description = "The runtime subnetwork name (GKE attaches here)."
  value       = module.vpc.subnetwork_name
}

output "pods_range_name" {
  description = "Secondary range name for GKE pods."
  value       = module.vpc.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for GKE services."
  value       = module.vpc.services_range_name
}

output "cluster_name" {
  description = "The shared runtime GKE cluster name."
  value       = module.cluster.name
}

output "workload_pool" {
  description = "The cluster Workload Identity pool (tenant agent-unit SAs bind here)."
  value       = module.cluster.workload_pool
}
