# ── VPC ─────────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID for this environment."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR for this environment."
  value       = module.network.vpc_cidr
}

# ── Subnets ─────────────────────────────────────────────────────────────────
output "public_subnet_ids" {
  description = "Public subnet IDs (ALB / NAT / bastion)."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS nodes / application workloads)."
  value       = module.network.private_subnet_ids
}

output "database_subnet_ids" {
  description = "Database subnet IDs (isolated tier — no Internet route)."
  value       = module.network.database_subnet_ids
}

output "db_subnet_group_name" {
  description = "DB subnet group name — pass to RDS modules."
  value       = module.network.db_subnet_group_name
}

output "elasticache_subnet_group_name" {
  description = "ElastiCache subnet group name — pass to Redis modules."
  value       = module.network.elasticache_subnet_group_name
}

# ── Bastion (only present when enable_bastion = true) ──────────────────────
output "bastion_instance_id" {
  description = "Bastion EC2 instance ID. Null when bastion is disabled."
  value       = try(module.bastion[0].instance_id, null)
}

output "bastion_public_ip" {
  description = "Bastion public IP for SSH. Null when bastion is disabled."
  value       = try(module.bastion[0].public_ip, null)
}

output "bastion_ssm_command" {
  description = "Copy-paste shell command to SSM into the bastion."
  value       = try(module.bastion[0].ssm_start_session_command, null)
}

# ── EKS (only present when enable_eks = true) ──────────────────────────────
output "eks_cluster_name" {
  description = "EKS cluster name. Null when disabled."
  value       = try(module.eks[0].cluster_name, null)
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint. Null when disabled."
  value       = try(module.eks[0].cluster_endpoint, null)
}

output "eks_cluster_version" {
  description = "EKS Kubernetes version."
  value       = try(module.eks[0].cluster_version, null)
}

output "eks_oidc_provider_arn" {
  description = "OIDC provider ARN. Pass to IRSA-using modules. Null when disabled."
  value       = try(module.eks[0].oidc_provider_arn, null)
}

output "eks_node_security_group_id" {
  description = "Worker node SG. Reference from RDS/ElastiCache SGs to allow pod traffic."
  value       = try(module.eks[0].node_security_group_id, null)
}

output "eks_kubeconfig_command" {
  description = "Copy-paste-ready aws eks update-kubeconfig command."
  value       = try(module.eks[0].kubeconfig_command, null)
}

# =============================================================================
#  cluster_summary - operator cheatsheet
#  ---------------------------------------------------------------------------
#  Single output that an on-call engineer can read and have everything they
#  need to operate this environment:
#    `terraform output cluster_summary`
#  Or via Makefile: `make summary-dev`
# =============================================================================

output "cluster_summary" {
  description = "Operator cheatsheet for this environment - everything you need on a 2am page."
  value = {
    environment = var.environment
    region      = var.aws_region
    vpc = {
      id   = module.network.vpc_id
      cidr = module.network.vpc_cidr
    }
    bastion = {
      enabled     = var.enable_bastion
      instance_id = try(module.bastion[0].instance_id, null)
      public_ip   = try(module.bastion[0].public_ip, null)
      ssm_command = try(module.bastion[0].ssm_start_session_command, null)
    }
    eks = {
      enabled            = var.enable_eks
      cluster_name       = try(module.eks[0].cluster_name, null)
      endpoint           = try(module.eks[0].cluster_endpoint, null)
      version            = try(module.eks[0].cluster_version, null)
      kubeconfig_command = try(module.eks[0].kubeconfig_command, null)
      access_pattern     = "kubectl from laptop on allow-listed IP, OR via bastion"
    }
    runbook = "https://github.com/techmahato/real-world-ecommerce-devops-project-eks-terraform/blob/main/docs/OPS_RUNBOOK.md"
  }
}
