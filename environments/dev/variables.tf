variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "project_name" {
  description = "Project identifier."
  type        = string
}

variable "environment" {
  description = "Environment name (dev or production)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the environment's VPC."
  type        = string
}

variable "availability_zones" {
  description = "AZs in which to create subnets."
  type        = list(string)
}

variable "owner" {
  description = "Team or person responsible for this environment."
  type        = string
  default     = "platform-team"
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs (recommended for production)."
  type        = bool
  default     = false
}
