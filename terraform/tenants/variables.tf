variable "environment" {
  description = "Which environment this apply targets. State is per (tenant, environment): env in the backend prefix, tenant in the workspace (ADR-0014)."
  type        = string

  validation {
    condition     = contains(["dev", "acc", "prod"], var.environment)
    error_message = "environment must be dev, acc, or prod."
  }
}

variable "tenant_slug" {
  description = "Tenant to deploy. Defaults to the Terraform workspace (ADR-0014: workspace-per-tenant). Set explicitly only in tests."
  type        = string
  default     = null
}

variable "billing_account" {
  description = "Billing account ID for tenant projects."
  type        = string
}

variable "parent_folder_id" {
  description = "Folder under which this environment's tenant projects are created (e.g. \"folders/111\")."
  type        = string
}

variable "keys_project_id" {
  description = "The central key-management project that holds every tenant's KMS keyring."
  type        = string
}

variable "region" {
  description = "Default region for regional resources. Constrained by the gcp.resourceLocations org policy."
  type        = string
  default     = "europe-west4"
}
