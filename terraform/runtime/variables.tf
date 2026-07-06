variable "environment" {
  description = "Which environment's runtime plane this is. One runtime project + state per environment."
  type        = string

  validation {
    condition     = contains(["dev", "acc", "prod"], var.environment)
    error_message = "environment must be dev, acc, or prod."
  }
}

variable "billing_account" {
  description = "Billing account for the runtime project."
  type        = string
}

variable "runtime_folder_id" {
  description = "The runtime/ folder these projects are created under (bootstrap output folder_ids.runtime)."
  type        = string
}

variable "composer_enabled" {
  description = <<-EOT
    Provision the shared Composer (Airflow) environment in this runtime plane. Default OFF:
    ADR-0016 parks Composer until a scheduled-batch data-pipeline tenant actually arrives —
    Temporal owns agentic/event-driven orchestration. The module stays versioned in
    platform-modules; flipping this to true is the entire re-activation path.
  EOT
  type        = bool
  default     = false
}

variable "region" {
  description = "Region for the runtime network and (later) cluster. Constrained by the resourceLocations org policy."
  type        = string
  default     = "europe-west4"
}
