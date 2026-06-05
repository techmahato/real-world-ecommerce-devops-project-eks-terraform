# =============================================================================
#  Bootstrap — Terraform & Provider Versions
#  Pinned to >= 1.10 because we use native S3 state locking elsewhere.
#  Bootstrap itself runs with LOCAL state (intentional chicken-and-egg break).
# =============================================================================

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}
