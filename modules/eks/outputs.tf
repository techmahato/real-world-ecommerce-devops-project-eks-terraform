# =============================================================================
#  EKS Module - Outputs
#  ---------------------------------------------------------------------------
#  Outputs are the public API. Downstream modules (RDS, ElastiCache, ALB,
#  observability stack) reference these.
# =============================================================================

# ── Cluster identifiers ────────────────────────────────────────────────────
output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "EKS API server endpoint URL."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Active Kubernetes version of the cluster."
  value       = aws_eks_cluster.this.version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA cert. Used by kubectl to verify the API server."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}


# ── Security groups (downstream modules reference these) ───────────────────
output "cluster_primary_security_group_id" {
  description = "Cluster's primary security group (created by EKS). RDS / ElastiCache SGs reference this to allow pod ingress."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_additional_security_group_id" {
  description = "Module-managed additional cluster SG. Use for caller-supplied control-plane ingress rules."
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "SG attached to all worker nodes. RDS/ElastiCache should allow ingress from this SG for pod-to-DB traffic."
  value       = aws_security_group.nodes.id
}


# ── KMS ────────────────────────────────────────────────────────────────────
output "kms_key_arn" {
  description = "KMS key ARN used for cluster encryption (either module-managed or caller-supplied)."
  value       = local.kms_key_arn
}


# ── OIDC / IRSA ────────────────────────────────────────────────────────────
output "oidc_provider_arn" {
  description = "OIDC provider ARN. Pass to IRSA-using modules so they can build trust policies."
  value       = try(aws_iam_openid_connect_provider.cluster[0].arn, null)
}

output "oidc_provider_url" {
  description = "OIDC issuer URL (without https://)."
  value       = try(replace(aws_iam_openid_connect_provider.cluster[0].url, "https://", ""), null)
}


# ── Node groups ────────────────────────────────────────────────────────────
output "node_groups" {
  description = "Map of node group name -> ARN, role, capacity type, instance types."
  value = {
    for k, v in aws_eks_node_group.this : k => {
      arn            = v.arn
      capacity_type  = v.capacity_type
      instance_types = v.instance_types
      labels         = v.labels
      taints         = v.taint
    }
  }
}

output "node_role_arn" {
  description = "IAM role ARN attached to worker nodes."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "IAM role name for nodes - useful for additional aws_iam_role_policy_attachment calls outside the module."
  value       = aws_iam_role.node.name
}


# ── Access entries ─────────────────────────────────────────────────────────
output "access_entries" {
  description = "Map of access entry name -> principal ARN, type."
  value = {
    for k, v in aws_eks_access_entry.this : k => {
      principal_arn = v.principal_arn
      type          = v.type
    }
  }
}


# ── Operator helpers ───────────────────────────────────────────────────────
output "kubeconfig_command" {
  description = "Copy-paste shell command to populate kubeconfig for kubectl."
  value       = "aws eks update-kubeconfig --region ${data.aws_region.current.name} --name ${aws_eks_cluster.this.name}"
}

data "aws_region" "current" {}
