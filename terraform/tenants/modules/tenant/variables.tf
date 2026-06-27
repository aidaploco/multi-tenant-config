variable "slug" {
  description = "Tenant slug (registry key)."
  type        = string
}

variable "tenant" {
  description = "The decoded tenant YAML object for one tenant."
  type        = any
}

variable "environment" {
  description = "Environment being deployed (dev|staging|prod)."
  type        = string
}

variable "billing_account" {
  description = "Billing account for the tenant project."
  type        = string
}

variable "parent_folder_id" {
  description = "Folder these tenant projects are created under for this environment."
  type        = string
}

variable "keys_project_id" {
  description = "Central key-management project that holds every tenant's KMS keyring (separation of duties)."
  type        = string
}

variable "region" {
  description = "Default region for regional resources."
  type        = string
}
