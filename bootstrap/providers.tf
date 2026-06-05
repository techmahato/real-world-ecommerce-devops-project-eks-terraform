# =============================================================================
#  Bootstrap — Provider Configuration
# =============================================================================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "shared"
      ManagedBy   = "terraform"
      Component   = "bootstrap-state-backend"
    }
  }
}
