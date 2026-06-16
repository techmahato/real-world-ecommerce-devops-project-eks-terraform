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
