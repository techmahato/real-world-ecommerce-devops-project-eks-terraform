// =============================================================================
//  TFLint configuration
//  Used by .github/workflows/terraform-validate.yml
// =============================================================================

config {
  call_module_type = "all"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.30.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

// ── Terraform language rules ─────────────────────────────────────────────
rule "terraform_required_version"            { enabled = true }
rule "terraform_required_providers"          { enabled = true }
rule "terraform_unused_declarations"         { enabled = true }
rule "terraform_documented_outputs"          { enabled = true }
rule "terraform_documented_variables"        { enabled = true }
rule "terraform_typed_variables"             { enabled = true }
rule "terraform_naming_convention"           { enabled = true }
rule "terraform_standard_module_structure"   { enabled = true }

// ── AWS-specific rules (tightening defaults) ─────────────────────────────
rule "aws_resource_missing_tags" {
  enabled = true
  tags    = ["Project", "Environment", "ManagedBy", "Owner"]
}
