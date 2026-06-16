# =============================================================================
#  Backend configuration — production environment
#  Replace `bucket` with the value from `bootstrap` output `state_bucket_id`.
# =============================================================================

bucket       = "ecommerce-eks-tfstate-441345502954-1780644411"
key          = "environments/production/terraform.tfstate"
region       = "ap-south-1"
encrypt      = true
use_lockfile = true
