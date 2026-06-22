# =============================================================================
#  EKS IAM
#  ---------------------------------------------------------------------------
#    1. Cluster role  - assumed by EKS to manage your VPC resources
#    2. Node role     - assumed by worker EC2 instances
#    3. OIDC provider - registers the cluster's OIDC issuer with AWS IAM
#                       (foundation of IRSA - per-pod IAM)
#
#  Both roles support caller-supplied additional policy attachments via the
#  cluster_role_additional_policy_arns / node_role_additional_policy_arns
#  variables, so you can extend without forking the module.
# =============================================================================


# =============================================================================
#  CLUSTER ROLE
# =============================================================================

resource "aws_iam_role" "cluster" {
  name = "${local.cluster_name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-eks-cluster-role"
  })
}

# Required AWS-managed policy.
resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Lets EKS create / manage VPC resources on your behalf.
resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# Caller-supplied additional policies. Map keys become a stable for_each id.
resource "aws_iam_role_policy_attachment" "cluster_additional" {
  for_each = var.cluster_role_additional_policy_arns

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}


# =============================================================================
#  NODE ROLE
#  ---------------------------------------------------------------------------
#  Attached to every worker node via instance profile. We attach:
#    - AmazonEKSWorkerNodePolicy            kubelet API
#    - AmazonEKS_CNI_Policy                 pod networking
#    - AmazonEC2ContainerRegistryReadOnly   ECR image pulls
#    - any additional policy from var.node_role_additional_policy_arns
#      (defaults include AmazonSSMManagedInstanceCore so SSM works)
# =============================================================================

resource "aws_iam_role" "node" {
  name = "${local.cluster_name}-eks-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-eks-node-role"
  })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_additional" {
  for_each = var.node_role_additional_policy_arns

  role       = aws_iam_role.node.name
  policy_arn = each.value
}


# =============================================================================
#  OIDC PROVIDER for IRSA
#  ---------------------------------------------------------------------------
#  IRSA lets a Kubernetes ServiceAccount assume an IAM role via OIDC token
#  exchange with STS. Required by:
#    - AWS Load Balancer Controller
#    - External Secrets Operator
#    - Cluster Autoscaler / Karpenter
#    - Almost any modern operator that calls AWS APIs
#
#  Skip with var.enable_irsa = false (very rare).
# =============================================================================

data "tls_certificate" "cluster" {
  count = var.enable_irsa ? 1 : 0

  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  count = var.enable_irsa ? 1 : 0

  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster[0].certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(local.module_tags, {
    Name = "${local.cluster_name}-eks-oidc"
  })
}
