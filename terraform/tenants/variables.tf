variable "environment" {
  description = "Which environment this apply targets. One state file per environment."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "billing_account" {
  description = "Billing account ID for tenant projects."
  type        = string
}

variable "parent_folder_id" {
  description = "Folder under which this environment's tenant projects are created (e.g. \"folders/111\" for tenants/dev)."
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
