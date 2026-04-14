// ============================================================================
// .tflint.hcl - Terraform linter config
// Owner: platform engineering
// Consumed by: .pre-commit-config.yaml + .github/workflows/iac-pr.yml
// ============================================================================

config {
  format           = "compact"
  call_module_type = "all"
  force            = false
}

plugin "terraform" {
  enabled = true
  version = "0.9.1"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

// --- core terraform hygiene ---
rule "terraform_comment_syntax"                { enabled = true }
rule "terraform_deprecated_index"              { enabled = true }
rule "terraform_deprecated_interpolation"      { enabled = true }
rule "terraform_documented_outputs"            { enabled = true }
rule "terraform_documented_variables"          { enabled = true }
rule "terraform_module_pinned_source"          { enabled = true }
rule "terraform_module_version"                { enabled = true }
rule "terraform_naming_convention"             { enabled = true }
rule "terraform_required_providers"            { enabled = true }
rule "terraform_required_version"              { enabled = true }
rule "terraform_standard_module_structure"     { enabled = true }
rule "terraform_typed_variables"               { enabled = true }
rule "terraform_unused_declarations"           { enabled = true }
rule "terraform_unused_required_providers"     { enabled = true }
rule "terraform_workspace_remote"              { enabled = true }

// --- aws sanity ---
rule "aws_resource_missing_tags" {
  enabled = true
  tags = [
    "cost_center",
    "owner_email",
    "environment",
    "service",
    "managed_by",
  ]
}
