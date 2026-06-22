# =============================================================================
#  EKS Module - Variables
#  ---------------------------------------------------------------------------
#  Sectioned for readability:
#    1. Identity                  - cluster name, version, region awareness
#    2. Networking                - subnet IDs, endpoint config
#    3. Authentication & access   - auth mode, access entries, OIDC/IRSA
#    4. Encryption (KMS)          - existing or module-managed customer KMS
#    5. Logging & observability   - control-plane log types, retention, insights
#    6. Cluster security group    - extension hooks
#    7. Node security group       - extension hooks
#    8. Node groups               - map of named groups (dev SPOT, prod ON_DEMAND etc)
#    9. IAM extension hooks       - additional policies for cluster + node roles
#    10. Add-ons                  - map of EKS-managed add-ons
#    11. Compliance               - extra tags / framework label
#
#  Default posture is "secure and production-grade":
#    - Authentication: API_AND_CONFIG_MAP (modern declarative access entries)
#    - bootstrap_cluster_creator_admin_permissions = false
#    - KMS envelope encryption ON, with key rotation
#    - All five control-plane log types ON
#    - OIDC/IRSA ON
#    - Cluster Insights ON
# =============================================================================


# =============================================================================
#  1. IDENTITY
# =============================================================================

variable "project_name" {
  description = "Project identifier used in cluster name and resource tags."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, production)."
  type        = string
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version. EKS supports the last 4 versions; pick one
    currently in support. To upgrade, change this value, plan, review the
    diff (a control-plane in-place upgrade), then apply. Bump add-on versions
    in the same PR if the new k8s version requires it.
  EOT
  type        = string
  default     = "1.30"
}


# =============================================================================
#  2. NETWORKING
#  ---------------------------------------------------------------------------
#  We accept *only* private subnets for both control-plane ENIs and node
#  groups. Public-subnet workers are an anti-pattern this module refuses to
#  support. The cluster API endpoint can still be exposed publicly (with a
#  CIDR allow-list) - that's separate from where the workers run.
# =============================================================================

variable "private_subnet_ids" {
  description = "Private subnet IDs for cluster ENIs and node groups. Pass module.network.private_subnet_ids."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS requires subnets in at least 2 AZs."
  }
}

variable "endpoint_private_access" {
  description = "Allow kubectl from inside the VPC."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Allow kubectl from the public internet (subject to endpoint_public_access_cidrs)."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to hit the public API endpoint. Required when endpoint_public_access=true. Refuses 0.0.0.0/0."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose the EKS API to 0.0.0.0/0. Use a /32 or office CIDR."
  }
}


# =============================================================================
#  3. AUTHENTICATION & ACCESS
#  ---------------------------------------------------------------------------
#  Two access mechanisms (you almost always want API_AND_CONFIG_MAP):
#
#    aws-auth ConfigMap   Legacy. Lives in kube-system. Edits go through
#                         kubectl - hard to audit, hard to recover from
#                         a typo (you can lock yourself out).
#    Access entries (API) Modern. Declarative IAM-style. Survives Terraform
#                         re-applies. This module uses access entries by
#                         default and treats the ConfigMap as a fallback.
#
#  bootstrap_cluster_creator_admin_permissions
#    AWS's default behaviour: whoever runs the create call becomes a cluster
#    admin via an implicit aws-auth entry. We turn this OFF so admin access
#    is *explicit* via the access_entries variable below. If you don't list
#    yourself there, you can't kubectl. That's the point.
# =============================================================================

variable "authentication_mode" {
  description = "Cluster authentication mode. API_AND_CONFIG_MAP supports both legacy aws-auth and modern access entries. Avoid CONFIG_MAP-only for new clusters."
  type        = string
  default     = "API_AND_CONFIG_MAP"

  validation {
    condition     = contains(["CONFIG_MAP", "API", "API_AND_CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode must be CONFIG_MAP, API, or API_AND_CONFIG_MAP."
  }
}

variable "enable_cluster_creator_admin_permissions" {
  description = "AWS-default implicit cluster admin for the create-time IAM principal. Off by default - use access_entries to grant admin explicitly."
  type        = bool
  default     = false
}

variable "access_entries" {
  description = <<-EOT
    Map of IAM principals -> cluster access entries. Keyed by a friendly name
    (e.g. "platform-admins"). Each entry maps an IAM principal ARN to one or
    more EKS-managed access policies.

    Supported access policy ARNs (use as the policy_arn value):
      arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
      arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy
      arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy
      arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy

    Example:
      access_entries = {
        platform-admins = {
          principal_arn = "arn:aws:iam::123:role/PlatformAdmin"
          type          = "STANDARD"
          policy_associations = {
            admin = {
              policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
              access_scope = { type = "cluster" }
            }
          }
        }
      }
  EOT
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string), [])
    user_name         = optional(string)
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        type       = string
        namespaces = optional(list(string))
      })
    })), {})
  }))
  default = {}
}

variable "enable_irsa" {
  description = "Provision the OIDC provider so workloads can use IAM Roles for Service Accounts (IRSA)."
  type        = bool
  default     = true
}


# =============================================================================
#  4. KMS - envelope encryption for Kubernetes secrets in etcd
#  ---------------------------------------------------------------------------
#  Two modes:
#    - Caller passes `kms_key_arn` -> module uses the existing key
#    - Caller leaves it null      -> module creates a customer-managed key
#  Either way, secrets in etcd are wrapped at the API server before storage.
#  Compliance auditors (PCI, SOC2, HIPAA) all check for this.
# =============================================================================

variable "kms_key_arn" {
  description = "ARN of an existing customer-managed KMS key for cluster encryption. When null, the module creates one."
  type        = string
  default     = null
}

variable "kms_key_deletion_window_in_days" {
  description = "Pending deletion window for the module-managed KMS key. 30 = max safety, 7 = min."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_in_days >= 7 && var.kms_key_deletion_window_in_days <= 30
    error_message = "kms_key_deletion_window_in_days must be between 7 and 30."
  }
}

variable "kms_enable_key_rotation" {
  description = "Enable annual KMS key rotation. Compliance frameworks require this."
  type        = bool
  default     = true
}


# =============================================================================
#  5. LOGGING & OBSERVABILITY
# =============================================================================

variable "enabled_cluster_log_types" {
  description = <<-EOT
    Control-plane log types to ship to CloudWatch. All five recommended for
    production. Auditors specifically look for `audit`.
      api               API server logs
      audit             Every authenticated/unauthenticated API call (audit)
      authenticator     IAM auth requests
      controllerManager Reconcilers (deployments, replicasets etc)
      scheduler         Pod scheduling decisions
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "CloudWatch retention for cluster logs. 90+ days recommended for prod."
  type        = number
  default     = 90
}

# Note: EKS Cluster Insights (upgrade-readiness checks) is a feature surfaced
# automatically by AWS on supported cluster versions. There's no provider
# argument to toggle it - query with `aws eks list-insights --cluster-name`.


# =============================================================================
#  6. CLUSTER SECURITY GROUP - extension hooks
#  ---------------------------------------------------------------------------
#  EKS auto-creates a cluster SG. We additionally allow the caller to pass:
#    - extra SG IDs to attach to the cluster ENIs (e.g. bastion SG)
#    - extra ingress/egress rules on the cluster SG
# =============================================================================

variable "additional_cluster_security_group_ids" {
  description = "Extra SG IDs to attach to the cluster's ENIs. Pass the bastion SG ID here so kubectl-from-bastion works."
  type        = list(string)
  default     = []
}

variable "additional_cluster_security_group_rules" {
  description = "Extra ingress/egress rules to add to the cluster SG. Map of name -> rule object."
  type = map(object({
    type                     = string # ingress | egress
    from_port                = number
    to_port                  = number
    protocol                 = string
    cidr_blocks              = optional(list(string))
    source_security_group_id = optional(string)
    description              = string
  }))
  default = {}
}


# =============================================================================
#  7. NODE SECURITY GROUP - extension hooks
# =============================================================================

variable "additional_node_security_group_rules" {
  description = "Extra ingress/egress rules on the worker-node SG. Use to allow ALB/NLB targets, RDS, etc."
  type = map(object({
    type                     = string
    from_port                = number
    to_port                  = number
    protocol                 = string
    cidr_blocks              = optional(list(string))
    source_security_group_id = optional(string)
    description              = string
  }))
  default = {}
}


# =============================================================================
#  8. NODE GROUPS - map shape
#  ---------------------------------------------------------------------------
#  One key per node group. Typical patterns:
#
#    DEV (cost-tuned, SPOT):
#      eks_node_groups = {
#        general-spot = {
#          capacity_type  = "SPOT"
#          instance_types = ["t3.medium", "t3.large", "t3a.medium"]
#          min_size       = 1
#          max_size       = 5
#          desired_size   = 2
#          labels         = { workload = "general", lifecycle = "spot" }
#        }
#      }
#
#    PROD (split system + app workloads onto on-demand pools):
#      eks_node_groups = {
#        system = {
#          capacity_type  = "ON_DEMAND"
#          instance_types = ["m5.large"]
#          min_size       = 2
#          max_size       = 4
#          desired_size   = 2
#          labels = { workload = "system", lifecycle = "on-demand" }
#          taints = [{ key = "system", value = "true", effect = "NO_SCHEDULE" }]
#        }
#        app = {
#          capacity_type  = "ON_DEMAND"
#          instance_types = ["m5.xlarge"]
#          labels = { workload = "app", lifecycle = "on-demand" }
#        }
#      }
#
#  Workloads then schedule via:
#      nodeSelector: { workload: app }
#      tolerations:
#        - key: system
#          operator: Equal
#          value: "true"
#          effect: NoSchedule
# =============================================================================

variable "eks_node_groups" {
  description = "Map of EKS managed node groups. See variable doc above for examples."
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND") # ON_DEMAND | SPOT
    min_size       = optional(number, 1)
    max_size       = optional(number, 4)
    desired_size   = optional(number, 2)
    disk_size_gb   = optional(number, 50)
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")
    key_name       = optional(string) # SSH key pair (null = SSM only)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string # NO_SCHEDULE | PREFER_NO_SCHEDULE | NO_EXECUTE
    })), [])
    # Optionally pin to a subset of subnets (e.g. one AZ only). Defaults to
    # all private_subnet_ids when null.
    subnet_ids = optional(list(string))
    # Per-node-group max-unavailable for rolling updates.
    max_unavailable = optional(number, 1)
  }))
  default = {}
}


# =============================================================================
#  9. IAM EXTENSION HOOKS
#  ---------------------------------------------------------------------------
#  Add caller-supplied policies to the cluster role and the node role
#  without forking the module.
# =============================================================================

variable "cluster_role_additional_policy_arns" {
  description = "Extra IAM policy ARNs to attach to the cluster role. Map of name -> ARN."
  type        = map(string)
  default     = {}
}

variable "node_role_additional_policy_arns" {
  description = "Extra IAM policy ARNs to attach to the node role (e.g. CloudWatchAgentServerPolicy)."
  type        = map(string)
  default = {
    # Bundled by default - SSM access lets you `start-session` into nodes
    # for debugging without bastion-hopping.
    SSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}


# =============================================================================
#  10. ADD-ONS - map shape
#  ---------------------------------------------------------------------------
#  Each key is the AWS-managed add-on name (vpc-cni, coredns, kube-proxy,
#  aws-ebs-csi-driver, adot, amazon-cloudwatch-observability, etc.).
#  Each value:
#    addon_version             null = AWS default for this k8s version
#    configuration_values      JSON-encoded add-on config (some addons accept it)
#    service_account_role_arn  IRSA role ARN if the addon needs one
#    before_compute            true = create before nodes (vpc-cni, kube-proxy)
#                              false = create after nodes (coredns, ebs-csi)
#                              IRSA-using addons MUST be after nodes.
#
#  The default set covers a functional cluster: vpc-cni + kube-proxy before
#  compute, coredns + ebs-csi after.
# =============================================================================

variable "cluster_addons" {
  description = "Map of EKS-managed add-ons. See variable docs."
  type = map(object({
    addon_version            = optional(string)
    configuration_values     = optional(string)
    service_account_role_arn = optional(string)
    before_compute           = optional(bool, false)
    resolve_conflicts        = optional(string, "OVERWRITE")
  }))
  default = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {
      before_compute = true
    }
    coredns = {
      before_compute = false
    }
    aws-ebs-csi-driver = {
      before_compute = false
      # service_account_role_arn is wired automatically by the module to the
      # ebs-csi IRSA role we create. Caller can override.
    }
  }
}


# =============================================================================
#  11. COMPLIANCE / TAGGING
# =============================================================================

variable "compliance_framework" {
  description = "Compliance framework label, applied as a Compliance tag on cluster + key resources. Set to 'none' to skip."
  type        = string
  default     = "none"
}

variable "additional_tags" {
  description = "Extra tags applied only to resources this module creates (on top of provider default_tags)."
  type        = map(string)
  default     = {}
}
