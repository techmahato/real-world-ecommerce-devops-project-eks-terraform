# =============================================================================
#  Bastion Module - Variables
#  ---------------------------------------------------------------------------
#  A bastion is one machine, one job: be the controlled jump-off point for
#  reaching private-tier workloads (EKS nodes, RDS, Redis). The variable
#  surface is deliberately small - if you need spot instances, custom AMIs,
#  or fancy block devices, you don't need a bastion, you need a generic EC2
#  module.
# =============================================================================

variable "project_name" {
  description = "Project identifier - used for resource naming and tags."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, production, etc.)."
  type        = string
}

# ── Where to put it ─────────────────────────────────────────────────────────
variable "vpc_id" {
  description = "VPC ID where the bastion lives. Pass module.network.vpc_id."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID for the bastion. Pass one of module.network.public_subnet_ids."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR - used for SG rules that allow bastion to reach private workloads."
  type        = string
}

# ── Compute size ────────────────────────────────────────────────────────────
variable "instance_type" {
  description = "EC2 instance type. t3.micro is sufficient for SSH + kubectl."
  type        = string
  default     = "t3.micro"
}

# ── AMI ─────────────────────────────────────────────────────────────────────
# We resolve the Ubuntu 24.04 AMI ID at apply time via the SSM Public
# Parameter that Canonical maintains. This means the module always picks
# the latest patched AMI without requiring a hardcoded ID per region.
#
# Override `ami_ssm_parameter` if you need a different distribution or
# architecture (the default is x86_64).
variable "ami_ssm_parameter" {
  description = "Public SSM parameter that resolves to an AMI ID. Default: latest Ubuntu 24.04 LTS x86_64."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ── SSH access ──────────────────────────────────────────────────────────────
variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair for SSH access. Set to null to skip SSH (SSM-only). Create the key pair in AWS console or via aws_key_pair before applying."
  type        = string
  default     = null
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH (port 22) to the bastion. Default empty list = no SSH ingress (SSM-only). Pass [\"X.X.X.X/32\"] for your office/home IP. Never use [\"0.0.0.0/0\"] in production."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.allowed_ssh_cidrs, "0.0.0.0/0")
    error_message = "Refusing to open SSH to the entire internet (0.0.0.0/0). Specify your office/home IP as a /32, e.g. \"203.0.113.42/32\"."
  }
}

# ── Storage ─────────────────────────────────────────────────────────────────
variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB. 20GB is plenty - bastion holds tools, not data."
  type        = number
  default     = 20
}

# ── Public IP / EIP ─────────────────────────────────────────────────────────
variable "associate_public_ip" {
  description = "Attach a stable Elastic IP. Required if you want SSH access from the internet."
  type        = bool
  default     = true
}

# ── Tags ────────────────────────────────────────────────────────────────────
# Canonical tags (Project, Environment, Owner, etc.) are applied by the
# AWS provider's default_tags block. The module sets only Name + Role.
