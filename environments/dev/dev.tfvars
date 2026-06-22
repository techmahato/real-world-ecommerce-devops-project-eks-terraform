# Dev environment values.
# Posture (NACLs, endpoints, hardening) is hardcoded in main.tf for prod parity.
# Only identity and cost-tuning knobs live here.

aws_region         = "ap-south-1"
project_name       = "ecommerce-eks"
environment        = "dev"
vpc_cidr           = "10.10.0.0/16"
availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
owner              = "platform-team"

# Cost: single NAT (cheaper, not HA), CloudWatch flow logs (easier to query).
single_nat_gateway    = true
flow_logs_destination = "cloud-watch-logs"

# Bastion - turn on when you need a jump box. Set ssh_key_name and
# allowed_ssh_cidrs to enable SSH; otherwise it's SSM-only.
enable_bastion            = false
bastion_instance_type     = "t3.micro"
bastion_ssh_key_name      = "bastion-host"
bastion_allowed_ssh_cidrs = ["49.37.8.68/32"]

# =============================================================================
#  EKS - dev cluster
# =============================================================================
enable_eks              = false
kubernetes_version      = "1.30"
eks_public_access_cidrs = ["49.37.8.68/32"]

# Cluster admins (IAM principals -> cluster-access-policy).
# At minimum, include the GitHub Actions deploy role so CI can apply
# Helm/CRD changes in the future.
eks_access_entries = {
  github-actions-deploy = {
    principal_arn = "arn:aws:iam::441345502954:role/tf-deployer-dev"
    policy_associations = {
      admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }
  # Add yourself or other operators here:
  # operator-arbind = {
  #   principal_arn = "arn:aws:iam::441345502954:user/arbind"
  #   policy_associations = {
  #     admin = {
  #       policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  #       access_scope = { type = "cluster" }
  #     }
  #   }
  # }
}

# Dev node groups - SPOT to save money. Multiple instance types so EKS can
# satisfy capacity even when one type's spot pool is exhausted.
eks_node_groups = {
  general-spot = {
    capacity_type  = "SPOT"
    instance_types = ["t3.medium", "t3.large", "t3a.medium"]
    min_size       = 1
    max_size       = 5
    desired_size   = 2
    disk_size_gb   = 50
    labels = {
      workload  = "general"
      lifecycle = "spot"
    }
    taints = []
  }
}

# Default add-ons (vpc-cni, kube-proxy, coredns, ebs-csi) are inherited from
# the variable's default. Override here only if you need a specific version
# or want to add another addon (e.g. amazon-cloudwatch-observability).
# eks_cluster_addons = { ... }

# =============================================================================
#  Budget alerts - cost protection
# =============================================================================
enable_budget_alerts = true
monthly_budget_usd   = 200
budget_alert_emails  = ["you@example.com", "arbind@cloudworkmates.com"]
