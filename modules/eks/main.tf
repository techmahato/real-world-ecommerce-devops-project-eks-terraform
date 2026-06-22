# =============================================================================
#  EKS Cluster
#  ---------------------------------------------------------------------------
#  This file owns:
#    - KMS key for envelope encryption (or the data lookup of an existing one)
#    - CloudWatch log group for control-plane logs
#    - The aws_eks_cluster itself
#    - Access entries (modern IAM-to-RBAC mapping)
#    - The time_sleep gate that lets before_compute add-ons settle before
#      nodes register
#
#  Dependencies between resources:
#    KMS key  -> cluster (encryption_config refers to it)
#    Log group -> cluster (auto-created by EKS otherwise; we manage it for
#                          retention control)
#    Cluster role + policies -> cluster
#    Cluster -> access entries (entries are created against an existing cluster)
#    Cluster -> OIDC provider (uses cluster identity issuer URL)
# =============================================================================

locals {
  cluster_name = "${var.project_name}-${var.environment}"

  # Module-managed KMS key is created only when caller didn't pass one.
  create_kms_key = var.kms_key_arn == null
  kms_key_arn    = local.create_kms_key ? aws_kms_key.eks[0].arn : var.kms_key_arn

  # Compliance tag is added when set; merged into additional_tags.
  module_tags = merge(
    var.additional_tags,
    var.compliance_framework != "none" ? { Compliance = var.compliance_framework } : {},
  )
}


# =============================================================================
#  KMS - module-managed customer key (skipped when caller passes kms_key_arn)
# =============================================================================

resource "aws_kms_key" "eks" {
  count = local.create_kms_key ? 1 : 0

  description             = "EKS envelope encryption for ${local.cluster_name}"
  deletion_window_in_days = var.kms_key_deletion_window_in_days
  enable_key_rotation     = var.kms_enable_key_rotation

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-eks-key"
  })
}

resource "aws_kms_alias" "eks" {
  count = local.create_kms_key ? 1 : 0

  name          = "alias/${local.cluster_name}-eks"
  target_key_id = aws_kms_key.eks[0].key_id
}


# =============================================================================
#  CLOUDWATCH LOG GROUP for control-plane logs
#  ---------------------------------------------------------------------------
#  EKS will auto-create this with the wrong name and "Never expire" retention
#  if we don't pre-create it. We pre-create it so we own retention.
# =============================================================================

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days
  kms_key_id        = local.kms_key_arn

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-cluster-logs"
  })
}


# =============================================================================
#  THE CLUSTER
#  ---------------------------------------------------------------------------
#  Notable choices:
#    access_config.authentication_mode = API_AND_CONFIG_MAP
#      Allows both legacy aws-auth and modern access entries. We use entries.
#
#    access_config.bootstrap_cluster_creator_admin_permissions
#      Off by default. Whoever runs the apply does NOT auto-get cluster
#      admin. Admin is granted via var.access_entries -> auditable, declarative.
#
#    encryption_config
#      Wraps Kubernetes Secret objects in etcd with the KMS key above.
#
#    enabled_cluster_log_types
#      Audit logs especially. Required by SOC2/PCI/HIPAA.
#
#    vpc_config.subnet_ids
#      Cluster ENIs live in private subnets only. Public-facing access is
#      controlled by endpoint_public_access + public_access_cidrs.
# =============================================================================

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  enabled_cluster_log_types = var.enabled_cluster_log_types

  access_config {
    authentication_mode                         = var.authentication_mode
    bootstrap_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions
  }

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.endpoint_public_access_cidrs : null
    security_group_ids = concat(
      [aws_security_group.cluster.id],
      var.additional_cluster_security_group_ids,
    )
  }

  encryption_config {
    provider {
      key_arn = local.kms_key_arn
    }
    resources = ["secrets"]
  }

  tags = merge(local.module_tags, {
    Name = local.cluster_name
  })

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,
    aws_iam_role_policy_attachment.cluster_additional,
    aws_cloudwatch_log_group.cluster,
  ]
}


# =============================================================================
#  ACCESS ENTRIES - the modern aws-auth replacement
#  ---------------------------------------------------------------------------
#  Each entry maps an IAM principal to one or more EKS-managed access
#  policies. Two resources per entry:
#    - aws_eks_access_entry           : registers the IAM principal
#    - aws_eks_access_policy_association : grants it a cluster-access policy
#
#  Caller controls via var.access_entries (see variables.tf for the shape).
# =============================================================================

resource "aws_eks_access_entry" "this" {
  for_each = var.access_entries

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.principal_arn
  type              = each.value.type
  kubernetes_groups = each.value.kubernetes_groups
  user_name         = each.value.user_name

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-access-${each.key}"
  })
}

# Flatten access_entries x policy_associations into a single map keyed by
# "<entry-key>:<association-key>" so each association becomes one resource.
locals {
  access_policy_associations = merge([
    for entry_key, entry in var.access_entries : {
      for assoc_key, assoc in entry.policy_associations :
      "${entry_key}:${assoc_key}" => {
        principal_arn = entry.principal_arn
        policy_arn    = assoc.policy_arn
        access_scope  = assoc.access_scope
      }
    }
  ]...)
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.access_policy_associations

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = each.value.access_scope.type
    namespaces = lookup(each.value.access_scope, "namespaces", null)
  }

  depends_on = [aws_eks_access_entry.this]
}


# =============================================================================
#  DATAPLANE READY GATE
#  ---------------------------------------------------------------------------
#  The pattern terraform-aws-modules/eks uses: a no-op time_sleep that depends
#  on the cluster, with a fixed delay. before_compute add-ons (vpc-cni,
#  kube-proxy) depend on the cluster directly; node groups depend on the
#  time_sleep. This gives those add-ons a window to land before nodes try to
#  join.
#
#  Without this, brand-new nodes occasionally race with vpc-cni: the node
#  registers, kubelet asks for a pod CIDR, vpc-cni isn't ready yet, kubelet
#  fails, node loops forever in NotReady. 30 seconds is enough margin.
# =============================================================================

resource "time_sleep" "dataplane_ready" {
  create_duration = "30s"

  triggers = {
    cluster_name     = aws_eks_cluster.this.name
    cluster_endpoint = aws_eks_cluster.this.endpoint
  }

  depends_on = [aws_eks_cluster.this]
}
