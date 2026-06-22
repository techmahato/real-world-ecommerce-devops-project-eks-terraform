# =============================================================================
#  Dev Environment — Composition
#  ---------------------------------------------------------------------------
#  Posture is hardcoded here (NACLs, endpoints, hardening) so dev and prod
#  share the same network behaviour. Only cost knobs come from tfvars.
#  See modules/network/README.md and modules/eks/README.md for design rationale.
# =============================================================================

locals {
  # Canonical tag schema — applied via provider default_tags to every taggable
  # resource. Per-resource Name + Tier tags are added by the network module.
  common_tags = {
    Project            = var.project_name
    Environment        = var.environment
    ManagedBy          = "terraform"
    Owner              = var.owner
    CostCenter         = var.cost_center
    DataClassification = var.data_classification
    Repository         = var.repository
  }
}

module "network" {
  source = "../../modules/network"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones

  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway
  flow_logs_destination  = var.flow_logs_destination

  enable_flow_logs       = true
  enable_dedicated_nacls = true
  enable_vpc_endpoints   = true
}

# =============================================================================
#  Bastion - jump box for reaching private workloads (and prod EKS API)
# =============================================================================

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  project_name = var.project_name
  environment  = var.environment

  vpc_id    = module.network.vpc_id
  vpc_cidr  = var.vpc_cidr
  subnet_id = module.network.public_subnet_ids[0]

  instance_type     = var.bastion_instance_type
  ssh_key_name      = var.bastion_ssh_key_name
  allowed_ssh_cidrs = var.bastion_allowed_ssh_cidrs
}

# =============================================================================
#  EKS - dev posture: public + private endpoint, public CIDR-restricted
# =============================================================================

module "eks" {
  count  = var.enable_eks ? 1 : 0
  source = "../../modules/eks"

  project_name = var.project_name
  environment  = var.environment

  kubernetes_version = var.kubernetes_version
  private_subnet_ids = module.network.private_subnet_ids

  # Dev: kubectl from your laptop OK, locked to the operator IPs in tfvars
  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_public_access_cidrs

  # Cluster admin: from tfvars (typically your IAM principal + the GHA deploy role)
  access_entries = var.eks_access_entries

  # Worker nodes
  eks_node_groups = var.eks_node_groups

  # Add-ons
  cluster_addons = var.eks_cluster_addons

  # When the bastion is up, allow it to reach the cluster's API SG
  additional_cluster_security_group_ids = var.enable_bastion ? [module.bastion[0].security_group_id] : []
}

# =============================================================================
#  Budget alerts - cost protection for managed-service operations
# =============================================================================

module "budget" {
  count  = var.enable_budget_alerts ? 1 : 0
  source = "../../modules/budget"

  project_name      = var.project_name
  environment       = var.environment
  monthly_limit_usd = var.monthly_budget_usd
  alert_emails      = var.budget_alert_emails
}
