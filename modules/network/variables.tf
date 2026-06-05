variable "environment" {
  description = "Environment name. Used in resource names and tags."
  type        = string
  validation {
    condition     = contains(["dev", "production"], var.environment)
    error_message = "environment must be one of: dev, production."
  }
}

variable "project_name" {
  description = "Project identifier. Used in resource names and tags."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g. 10.10.0.0/16). Must be /16 to fit three /20 tiers across up to 4 AZs each."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "availability_zones" {
  description = "AZs in which to create subnets. Subnet count per tier equals AZ count."
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) >= 2 && length(var.availability_zones) <= 4
    error_message = "Provide between 2 and 4 availability zones."
  }
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch Logs. Recommended for production."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Retention period for VPC flow logs (days). Only used when enable_flow_logs = true."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Common tags to apply to every resource created by this module."
  type        = map(string)
  default     = {}
}
