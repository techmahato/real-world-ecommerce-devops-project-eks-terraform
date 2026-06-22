# =============================================================================
#  EKS Add-ons (managed by AWS)
#  ---------------------------------------------------------------------------
#  Caller passes a map of addon name -> config in var.cluster_addons.
#  Each entry can specify:
#    addon_version             null = AWS default for cluster's k8s version
#    configuration_values      JSON-encoded addon config (some addons accept it)
#    service_account_role_arn  IRSA role ARN (only for addons that need one)
#    before_compute            true = create before nodes (vpc-cni, kube-proxy)
#                              false = create after nodes (coredns, ebs-csi)
#    resolve_conflicts         OVERWRITE (default) | NONE | PRESERVE
#
#  Why split before/after compute?
#    vpc-cni and kube-proxy must be configurable BEFORE nodes register,
#    otherwise nodes come up briefly without networking. We use the
#    time_sleep.dataplane_ready resource as the gate:
#      before_compute addons depend on the cluster directly
#      after_compute  addons depend on the node group (via the gate)
#
#  EBS CSI driver:
#    Needs IRSA. The module auto-creates an IRSA role and wires it in if
#    aws-ebs-csi-driver appears in cluster_addons AND the caller didn't pass
#    their own service_account_role_arn for that addon.
# =============================================================================


# Split addons by before_compute flag for clarity in dependency wiring.
locals {
  before_compute_addons = {
    for name, cfg in var.cluster_addons :
    name => cfg if cfg.before_compute
  }
  after_compute_addons = {
    for name, cfg in var.cluster_addons :
    name => cfg if !cfg.before_compute
  }

  # Auto-wire EBS CSI driver IRSA role when caller didn't supply one.
  ebs_csi_in_addons = contains(keys(var.cluster_addons), "aws-ebs-csi-driver")
}


# ── Addons that must exist BEFORE nodes ────────────────────────────────────
resource "aws_eks_addon" "before_compute" {
  for_each = local.before_compute_addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = each.value.addon_version
  configuration_values        = each.value.configuration_values
  service_account_role_arn    = each.value.service_account_role_arn
  resolve_conflicts_on_create = each.value.resolve_conflicts
  resolve_conflicts_on_update = each.value.resolve_conflicts

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-${each.key}"
  })

  # Only depend on the cluster - we want these BEFORE nodes register.
  depends_on = [aws_eks_cluster.this]
}


# ── Addons that come AFTER nodes ───────────────────────────────────────────
resource "aws_eks_addon" "after_compute" {
  for_each = local.after_compute_addons

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.key

  addon_version        = each.value.addon_version
  configuration_values = each.value.configuration_values

  # Auto-wire ebs-csi IRSA role when caller didn't supply one.
  service_account_role_arn = (
    each.key == "aws-ebs-csi-driver" && each.value.service_account_role_arn == null
    ? aws_iam_role.ebs_csi[0].arn
    : each.value.service_account_role_arn
  )

  resolve_conflicts_on_create = each.value.resolve_conflicts
  resolve_conflicts_on_update = each.value.resolve_conflicts

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-${each.key}"
  })

  depends_on = [aws_eks_node_group.this]
}


# =============================================================================
#  EBS CSI DRIVER - IRSA role
#  ---------------------------------------------------------------------------
#  Created only when:
#    1. enable_irsa = true   (we have an OIDC provider)
#    2. aws-ebs-csi-driver is in cluster_addons
#  Caller can override by passing their own service_account_role_arn for the
#  addon, in which case this role is still created but unused (cheap).
# =============================================================================

resource "aws_iam_role" "ebs_csi" {
  count = var.enable_irsa && local.ebs_csi_in_addons ? 1 : 0

  name = "${local.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.cluster[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.cluster[0].url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.cluster[0].url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-ebs-csi-irsa"
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count = var.enable_irsa && local.ebs_csi_in_addons ? 1 : 0

  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
