# =============================================================================
#  Dev Environment — Composition
#  ---------------------------------------------------------------------------
#  Posture is hardcoded here (NACLs, endpoints, hardening) so dev and prod
#  share the same network behaviour. Only cost knobs come from tfvars.
#  See modules/network/README.md for the design rationale.
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

  # Identity
  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones

  # Cost knobs (from tfvars)
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway
  flow_logs_destination  = var.flow_logs_destination

  # Posture — identical to prod, hardcoded so it can never drift
  enable_flow_logs       = true
  enable_dedicated_nacls = true
  enable_vpc_endpoints   = true

  # No `tags` input — canonical tags flow in via provider default_tags
  # (see locals.common_tags + providers.tf default_tags block).
}

# =============================================================================
#  Bastion host - jump box for reaching private workloads
#  ---------------------------------------------------------------------------
#  Conditionally created via count = enable_bastion ? 1 : 0 so we can turn
#  the bastion off without removing the module call from this file.
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
