# =============================================================================
#  Bootstrap — Provider Configuration
#  ---------------------------------------------------------------------------
#  default_tags applies the canonical tag schema to every taggable resource
#  the AWS provider creates in this root. Component is hardcoded because
#  bootstrap is the only thing in this Terraform root.
# =============================================================================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project            = var.project_name
      Environment        = "shared"
      ManagedBy          = "terraform"
      Owner              = var.owner
      CostCenter         = var.cost_center
      DataClassification = var.data_classification
      Repository         = var.repository
      Component          = "state-backend"
    }
  }
}
