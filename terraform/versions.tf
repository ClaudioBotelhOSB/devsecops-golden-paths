// ============================================================================
// terraform/versions.tf
// Root module pins. Owner: platform engineering
// ============================================================================

terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    # Backend configuration is injected at init time via
    // `terraform init -backend-config=backends/<env>.hcl`.
  }
}
