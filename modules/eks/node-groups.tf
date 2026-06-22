# =============================================================================
#  Managed Node Groups (one per entry in var.eks_node_groups)
#  ---------------------------------------------------------------------------
#  Two pieces per group:
#    1. aws_launch_template - so we can attach our explicit node SG, set
#                             EBS encryption + IMDSv2, and pass the SSH key
#                             when caller supplied one.
#    2. aws_eks_node_group  - references the launch template + the node role.
#
#  Why a launch template instead of letting EKS auto-generate one?
#    - To attach our own aws_security_group.nodes (predictable SG ID for RDS/
#      ElastiCache rules, custom rules, audit clarity)
#    - To enforce IMDSv2 (mitigates SSRF -> credential theft)
#    - To enforce EBS encryption (compliance frameworks check this)
#    - To set the SSH key per node group (caller-supplied)
#
#  Lifecycle:
#    - desired_size is ignored on update so a future cluster autoscaler
#      doesn't fight Terraform.
#    - launch_template version is `$Latest` so config edits propagate via
#      the standard rolling-update mechanism.
# =============================================================================

# Latest EKS-optimised AMI for the AMI type. We let EKS pick by version,
# rather than pinning to a specific AMI ID, so security patches flow in
# automatically when the node group rolls.
locals {
  node_group_subnet_ids_default = var.private_subnet_ids
}


# ── Launch template per node group ─────────────────────────────────────────
resource "aws_launch_template" "node" {
  for_each = var.eks_node_groups

  name_prefix = "${local.cluster_name}-${each.key}-"
  description = "Launch template for EKS node group ${each.key} in ${local.cluster_name}"

  vpc_security_group_ids = [aws_security_group.nodes.id]

  # Hardened EBS root volume - encrypted, gp3 by default.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = each.value.disk_size_gb
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 only. v1 is the source of nearly every SSRF -> credential-theft
  # incident in EC2 history. http_put_response_hop_limit = 2 lets pod sidecars
  # reach IMDS through the host (1 would block the kubelet itself).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  # SSH key only attached when the caller passed key_name. Without it, SSM
  # is the only access path - which is the recommended posture.
  key_name = each.value.key_name

  # Tags applied to the EC2 instances themselves (different from node group
  # AWS tags, and different again from Kubernetes labels).
  tag_specifications {
    resource_type = "instance"
    tags = merge(local.module_tags, {
      Name      = "${local.cluster_name}-${each.key}"
      NodeGroup = each.key
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.module_tags, {
      Name      = "${local.cluster_name}-${each.key}-volume"
      NodeGroup = each.key
    })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = merge(local.module_tags, {
      Name      = "${local.cluster_name}-${each.key}-eni"
      NodeGroup = each.key
    })
  }

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-${each.key}-lt"
  })

  lifecycle {
    create_before_destroy = true
  }
}


# ── The node groups themselves ─────────────────────────────────────────────
resource "aws_eks_node_group" "this" {
  for_each = var.eks_node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.cluster_name}-${each.key}"
  node_role_arn   = aws_iam_role.node.arn

  subnet_ids = each.value.subnet_ids != null ? each.value.subnet_ids : local.node_group_subnet_ids_default

  capacity_type  = each.value.capacity_type
  instance_types = each.value.instance_types
  ami_type       = each.value.ami_type

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  update_config {
    max_unavailable = each.value.max_unavailable
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  # Kubernetes labels applied to every node in this group. Workloads use
  # these for nodeSelector / nodeAffinity scheduling.
  labels = each.value.labels

  # Kubernetes taints applied to every node. Pods that don't tolerate the
  # taint won't schedule here. Use for "system-only" pools.
  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = lookup(taint.value, "value", null)
      effect = taint.value.effect
    }
  }

  tags = merge(local.module_tags, {
    Name      = "${local.cluster_name}-${each.key}"
    NodeGroup = each.key
  })

  lifecycle {
    # The autoscaler (when you eventually add it) will modify desired_size.
    # Don't fight it.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_additional,

    # Wait for before-compute add-ons to settle, otherwise nodes can join
    # before vpc-cni is ready.
    time_sleep.dataplane_ready,
  ]
}
