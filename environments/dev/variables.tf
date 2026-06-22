# Dev environment — only the variables that tfvars actually sets.
# Posture knobs (NACLs, endpoints, hardening) are hardcoded in main.tf.

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "project_name" {
  description = "Project identifier."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block (must be /16)."
  type        = string
}

variable "availability_zones" {
  description = "AZs in which to create subnets."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Single shared NAT (true=dev, false=prod)."
  type        = bool
}

variable "flow_logs_destination" {
  description = "Flow log destination: cloud-watch-logs (dev) or s3 (prod)."
  type        = string
}

# ── Tag schema (matches bootstrap + production) ─────────────────────────────
variable "owner" {
  description = "Team or person responsible for this environment."
  type        = string
  default     = "platform-team"
}

variable "cost_center" {
  description = "Bill-back / chargeback identifier used by Finance."
  type        = string
  default     = "eng-platform"
}

variable "data_classification" {
  description = "Sensitivity of data stored: public, internal, confidential, or restricted."
  type        = string
  default     = "internal"

  validation {
    condition     = contains(["public", "internal", "confidential", "restricted"], var.data_classification)
    error_message = "data_classification must be one of: public, internal, confidential, restricted."
  }
}

variable "repository" {
  description = "Source repository URL — answers 'where does this resource come from?'"
  type        = string
  default     = "github.com/your-org/eks-terraform"
}

# ── Bastion ─────────────────────────────────────────────────────────────────
variable "enable_bastion" {
  description = "Provision a bastion host. Off by default — flip on in tfvars when you need a jump box."
  type        = bool
  default     = false
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion."
  type        = string
  default     = "t3.micro"
}

variable "bastion_ssh_key_name" {
  description = "EC2 key pair name for SSH access. Set to null for SSM-only mode."
  type        = string
  default     = null
}

variable "bastion_allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH to the bastion. Empty list = SSM-only. 0.0.0.0/0 is rejected."
  type        = list(string)
  default     = []
}

# ── EKS ─────────────────────────────────────────────────────────────────────
variable "enable_eks" {
  description = "Provision the EKS cluster. Off by default - cluster costs ~$110/mo while running."
  type        = bool
  default     = false
}

variable "kubernetes_version" {
  description = "Kubernetes minor version."
  type        = string
  default     = "1.30"
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to hit the public EKS API endpoint (kubectl from operator IPs)."
  type        = list(string)
  default     = []
}

variable "eks_node_groups" {
  description = "Map of EKS managed node groups for dev. SPOT-friendly defaults."
  type = map(object({
    instance_types  = list(string)
    capacity_type   = optional(string, "ON_DEMAND")
    min_size        = optional(number, 1)
    max_size        = optional(number, 4)
    desired_size    = optional(number, 2)
    disk_size_gb    = optional(number, 50)
    ami_type        = optional(string, "AL2023_x86_64_STANDARD")
    key_name        = optional(string)
    labels          = optional(map(string), {})
    taints          = optional(list(object({ key = string, value = optional(string), effect = string })), [])
    subnet_ids      = optional(list(string))
    max_unavailable = optional(number, 1)
  }))
  default = {}
}

variable "eks_access_entries" {
  description = "Cluster access entries. Map IAM principals to EKS access policies."
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

variable "eks_cluster_addons" {
  description = "EKS-managed addons. Override default versions or add new addons."
  type = map(object({
    addon_version            = optional(string)
    configuration_values     = optional(string)
    service_account_role_arn = optional(string)
    before_compute           = optional(bool, false)
    resolve_conflicts        = optional(string, "OVERWRITE")
  }))
  default = {
    vpc-cni            = { before_compute = true }
    kube-proxy         = { before_compute = true }
    coredns            = { before_compute = false }
    aws-ebs-csi-driver = { before_compute = false }
  }
}

# ── Budget alerts ───────────────────────────────────────────────────────────
variable "enable_budget_alerts" {
  description = "Provision an AWS Budget + SNS email alerts for this environment's monthly spend."
  type        = bool
  default     = false
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD. Forecast-based alerts fire as projected spend crosses thresholds."
  type        = number
  default     = 200
}

variable "budget_alert_emails" {
  description = "Recipients for budget alerts. Each must click the SNS confirmation email before they start receiving alerts."
  type        = list(string)
  default     = []
}
