// ============================================================================
// terraform/variables.tf
//
// Every variable is REQUIRED (no default) unless marked optional. This is
// intentional: the template must not ship with a hardcoded region, owner,
// or cost center that a downstream team might inherit by accident.
// ============================================================================

variable "environment" {
  description = "Deployment environment: preview|dev|staging|prod."
  type        = string
  validation {
    condition     = contains(["preview", "dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of preview|dev|staging|prod."
  }
}

variable "region" {
  description = "Cloud region for the stack (e.g. aws:us-east-1)."
  type        = string
}

variable "service" {
  description = "Service name. Propagates into every tag block for audit."
  type        = string
}

variable "owner_email" {
  description = "Owning contact for the stack. Enforced by tflint + the FinOps tag-policy gate in iac-pr.yml."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.owner_email))
    error_message = "owner_email must be a valid email address."
  }
}

variable "cost_center" {
  description = "FinOps attribution. Must match .platform/budgets.yaml cost_center_allowlist."
  type        = string
}

// Optional below --------------------------------------------------------------

variable "ttl" {
  description = "RFC3339 expiration timestamp for ephemeral envs (null for prod)."
  type        = string
  default     = null
}

variable "bucket_suffix" {
  description = "Random suffix used to avoid S3 global name collisions on preview."
  type        = string
  default     = ""
}
