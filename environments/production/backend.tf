# =============================================================================
#  Remote backend declaration — values come from backend.hcl at init time:
#    terraform init -backend-config=backend.hcl
#
#  S3-only backend with native state locking (Terraform 1.10+).
# =============================================================================

terraform {
  backend "s3" {}
}
