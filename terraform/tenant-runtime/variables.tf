variable "environment" {
  description = "Which environment's shared cluster to provision tenant namespaces on."
  type        = string

  validation {
    condition     = contains(["dev", "acc", "prod"], var.environment)
    error_message = "environment must be dev, acc, or prod."
  }
}

variable "cluster_mode" {
  description = "Which cluster this root targets: connectgateway = the private GKE cluster via Fleet Connect Gateway (real GCP); kind = the local mock-first plane (ADR-0018) — no GCP credentials needed, state must be local (scripts/kind/up.sh writes a backend override)."
  type        = string
  default     = "connectgateway"

  validation {
    condition     = contains(["kind", "connectgateway"], var.cluster_mode)
    error_message = "cluster_mode must be kind or connectgateway."
  }
}

variable "region" {
  description = "Region (for the google provider)."
  type        = string
  default     = "europe-west4"
}
