# =============================================================================
#  Backend configuration — production environment
#  Replace `bucket` with the value from `bootstrap` output `state_bucket_id`.
# =============================================================================

bucket       = "ecommerce-eks-tfstate-CHANGE-ME"
key          = "environments/production/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true
