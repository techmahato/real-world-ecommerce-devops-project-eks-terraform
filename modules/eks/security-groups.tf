# =============================================================================
#  Security Groups
#  ---------------------------------------------------------------------------
#  EKS auto-creates a "cluster primary security group" that handles the
#  control-plane <-> node traffic. We additionally manage:
#
#    aws_security_group.cluster   - additional cluster SG attached via
#                                   vpc_config.security_group_ids. Provides
#                                   a stable handle for caller-supplied
#                                   ingress rules (kubectl from VPC, etc.)
#
#    aws_security_group.nodes     - shared SG attached to every worker node
#                                   group. Carries the rules that let nodes
#                                   talk to each other and to the cluster
#                                   primary SG.
#
#  Why explicit SGs instead of relying on EKS defaults?
#    - Auditors want every ingress/egress declared in code
#    - Stable IDs you can reference from RDS / ElastiCache SGs
#    - Caller-supplied additional rules without forking the module
# =============================================================================


# =============================================================================
#  CLUSTER SG (additional, attached to control-plane ENIs)
# =============================================================================

resource "aws_security_group" "cluster" {
  name        = "${local.cluster_name}-cluster-additional"
  description = "Additional cluster SG: caller-supplied ingress/egress rules for the EKS control plane"
  # We can't reference aws_eks_cluster.this.vpc_config[0].vpc_id here -
  # circular dep. The cluster's primary SG is in the same VPC as the
  # subnets, and we have those.
  vpc_id = data.aws_subnet.first.vpc_id

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-cluster-additional"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Look up the VPC ID from the first subnet caller supplied.
data "aws_subnet" "first" {
  id = var.private_subnet_ids[0]
}

# Caller-supplied extra cluster SG rules.
resource "aws_security_group_rule" "cluster_additional" {
  for_each = var.additional_cluster_security_group_rules

  security_group_id        = aws_security_group.cluster.id
  type                     = each.value.type
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  protocol                 = each.value.protocol
  cidr_blocks              = each.value.cidr_blocks
  source_security_group_id = each.value.source_security_group_id
  description              = each.value.description
}


# =============================================================================
#  NODE SG (attached to every node group via launch_template)
#  ---------------------------------------------------------------------------
#  Base rules:
#    - Allow all traffic between nodes in this SG (pod-to-pod across nodes)
#    - Allow ingress from the cluster primary SG on common kubelet+webhook
#      ports (10250, 443, 53)
#    - Allow all egress (nodes pull images, call AWS APIs, hit external APIs)
#
#  These are the recommended baseline rules from the AWS EKS docs.
#  Caller can add more via additional_node_security_group_rules.
# =============================================================================

resource "aws_security_group" "nodes" {
  name        = "${local.cluster_name}-nodes"
  description = "EKS worker nodes SG (pod-to-pod, kubelet, all egress)"
  vpc_id      = data.aws_subnet.first.vpc_id

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-nodes"
    # This tag is recognised by Cluster Autoscaler and AWS LB Controller
    # for SG discovery. Cheap; harmless if those controllers aren't installed.
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Pods on different nodes need to reach each other. EKS docs recommend allow-all
# within the node SG.
resource "aws_security_group_rule" "nodes_internal" {
  type                     = "ingress"
  description              = "All traffic within the node SG (pod-to-pod across nodes)"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.nodes.id
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
}

# Cluster primary SG -> nodes on TCP 443 (webhooks like cert-manager,
# admission controllers).
resource "aws_security_group_rule" "nodes_from_cluster_primary_443" {
  type                     = "ingress"
  description              = "Cluster API to webhook listeners on nodes"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
}

# Cluster primary SG -> nodes on kubelet (10250).
resource "aws_security_group_rule" "nodes_from_cluster_primary_kubelet" {
  type                     = "ingress"
  description              = "Cluster API to kubelet on nodes"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
}

# DNS within the cluster - both CoreDNS and any ad-hoc resolvers on nodes.
resource "aws_security_group_rule" "nodes_dns_tcp" {
  type                     = "ingress"
  description              = "DNS over TCP from anywhere in the node SG"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.nodes.id
  from_port                = 53
  to_port                  = 53
  protocol                 = "tcp"
}

resource "aws_security_group_rule" "nodes_dns_udp" {
  type                     = "ingress"
  description              = "DNS over UDP from anywhere in the node SG"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.nodes.id
  from_port                = 53
  to_port                  = 53
  protocol                 = "udp"
}

# Egress: nodes need to reach pretty much everything (NAT, VPC endpoints,
# AWS APIs). Locking egress further is generally not worth the operational pain.
resource "aws_security_group_rule" "nodes_egress_all" {
  type              = "egress"
  description       = "All egress (NAT, AWS APIs, VPC endpoints, external services)"
  security_group_id = aws_security_group.nodes.id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
}

# Caller-supplied extra node SG rules.
resource "aws_security_group_rule" "nodes_additional" {
  for_each = var.additional_node_security_group_rules

  security_group_id        = aws_security_group.nodes.id
  type                     = each.value.type
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  protocol                 = each.value.protocol
  cidr_blocks              = each.value.cidr_blocks
  source_security_group_id = each.value.source_security_group_id
  description              = each.value.description
}
