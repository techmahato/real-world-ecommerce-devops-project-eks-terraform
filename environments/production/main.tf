# =============================================================================
#  Production Environment — Composition
# =============================================================================

locals {
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
#  Bastion - REQUIRED to manage the prod EKS cluster (private endpoint only)
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
#  EKS - prod posture: PRIVATE API endpoint ONLY
#  ---------------------------------------------------------------------------
#  No public endpoint. kubectl access requires the bastion:
#    aws ssm start-session --target <bastion-id>
#    aws eks update-kubeconfig --name <cluster> --region <region>
#    kubectl get nodes
#
#  Compliance: data_classification=confidential by default,
#  compliance_framework configurable (e.g. soc2, pci).
# =============================================================================

module "eks" {
  count  = var.enable_eks ? 1 : 0
  source = "../../modules/eks"

  project_name = var.project_name
  environment  = var.environment

  kubernetes_version = var.kubernetes_version
  private_subnet_ids = module.network.private_subnet_ids

  endpoint_private_access      = true
  endpoint_public_access       = false
  endpoint_public_access_cidrs = []

  access_entries  = var.eks_access_entries
  eks_node_groups = var.eks_node_groups
  cluster_addons  = var.eks_cluster_addons

  # Bastion SG must reach the cluster ENIs - this is the path kubectl takes
  additional_cluster_security_group_ids = var.enable_bastion ? [module.bastion[0].security_group_id] : []

  compliance_framework = var.compliance_framework
}

# =============================================================================
#  Budget alerts - cost protection
# =============================================================================

module "budget" {
  count  = var.enable_budget_alerts ? 1 : 0
  source = "../../modules/budget"

  project_name      = var.project_name
  environment       = var.environment
  monthly_limit_usd = var.monthly_budget_usd
  alert_emails      = var.budget_alert_emails
}
