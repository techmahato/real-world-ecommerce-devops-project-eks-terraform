# Production environment values.

aws_region         = "ap-south-1"
project_name       = "ecommerce-eks"
environment        = "production"
vpc_cidr           = "10.30.0.0/16"
availability_zones = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
owner              = "platform-team"

# Cost-tuned: single NAT (EIP quota constrained), S3 flow logs.
single_nat_gateway    = true
flow_logs_destination = "s3"

# Bastion - REQUIRED for managing the cluster (private API endpoint).
# Set to true once you're ready to spin up + manage the cluster.
enable_bastion            = false
bastion_instance_type     = "t3.micro"
bastion_ssh_key_name      = "bastion-host"
bastion_allowed_ssh_cidrs = ["49.37.8.68/32"]

# =============================================================================
#  EKS - prod cluster (private only)
# =============================================================================
enable_eks         = false
kubernetes_version = "1.30"

# Compliance label - applied as Compliance tag on cluster + KMS + log group.
compliance_framework = "none"

# Cluster admins. Conservative in prod - usually just the GHA deploy role.
# Add break-glass operators only when needed.
eks_access_entries = {
  github-actions-deploy = {
    principal_arn = "arn:aws:iam::441345502954:role/tf-deployer-production"
    policy_associations = {
      admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" }
      }
    }
  }
}

# Prod node groups - ON_DEMAND, split into system (tainted, for kube-system,
# operators) and app (untainted, for application workloads). Workloads use
# tolerations to land on the right pool.
eks_node_groups = {
  system = {
    capacity_type  = "ON_DEMAND"
    instance_types = ["m5.large"]
    min_size       = 2
    max_size       = 4
    desired_size   = 2
    disk_size_gb   = 100
    labels = {
      workload  = "system"
      lifecycle = "on-demand"
    }
    taints = [{
      key    = "system"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]
  }
  app = {
    capacity_type  = "ON_DEMAND"
    instance_types = ["m5.xlarge"]
    min_size       = 2
    max_size       = 6
    desired_size   = 2
    disk_size_gb   = 100
    labels = {
      workload  = "app"
      lifecycle = "on-demand"
    }
    taints = []
  }
}

# Default add-ons inherit from the variable. Override here only to pin
# versions or add new addons.
# eks_cluster_addons = { ... }

# =============================================================================
#  Budget alerts - cost protection (PROD - lower threshold for tighter control)
# =============================================================================
enable_budget_alerts = true
monthly_budget_usd   = 500
budget_alert_emails  = ["you@example.com", "arbind@cloudworkmates.com"]
