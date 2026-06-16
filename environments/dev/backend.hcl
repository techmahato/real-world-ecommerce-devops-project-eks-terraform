# =============================================================================
#  Backend configuration — dev environment
#  Replace `bucket` with the value from `bootstrap` output `state_bucket_id`.
# =============================================================================

bucket       = "ecommerce-eks-tfstate-CHANGE-ME"
key          = "environments/dev/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true
