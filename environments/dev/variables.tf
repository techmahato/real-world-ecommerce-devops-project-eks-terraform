# =============================================================================
#  Dev Environment — Variable Declarations
#  ---------------------------------------------------------------------------
#  Most of these variables are passed straight through to the network module.
#  Defaults here favor "cheap dev" — single NAT, short CW retention. Override
#  in dev.tfvars for environment-specific values.
# =============================================================================

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

# ── NAT mode ────────────────────────────────────────────────────────────────
variable "single_nat_gateway" {
  description = "Use a single shared NAT Gateway. Recommended on for dev (cost), off for prod."
  type        = bool
  default     = true
}

variable "one_nat_gateway_per_az" {
  description = "One NAT per AZ. Recommended on for prod (HA), off for dev."
  type        = bool
  default     = false
}

# ── Flow logs ───────────────────────────────────────────────────────────────
variable "enable_flow_logs" {
  description = "Enable VPC flow logs."
  type        = bool
  default     = true
}

variable "flow_logs_destination" {
  description = "Destination for flow logs: cloud-watch-logs or s3."
  type        = string
  default     = "cloud-watch-logs"
}

variable "flow_logs_retention_days" {
  description = "CloudWatch retention. Ignored when destination is s3."
  type        = number
  default     = 30
}

variable "flow_logs_s3_lifecycle_days" {
  description = "Days before flow log objects transition to Glacier IR. Only used when destination is s3."
  type        = number
  default     = 90
}

# ── Hardening toggles ───────────────────────────────────────────────────────
variable "enable_dedicated_nacls" {
  description = "Per-tier NACLs. Recommended on. Disable only for short-lived dev VPCs where you need fully open NACLs."
  type        = bool
  default     = true
}

# ── VPC endpoints ───────────────────────────────────────────────────────────
variable "enable_vpc_endpoints" {
  description = "Provision VPC endpoints (S3 gateway + interface endpoints for ECR/EKS/STS/Logs/etc)."
  type        = bool
  default     = true
}

variable "enable_s3_gateway_endpoint" {
  description = "Create the S3 gateway endpoint (free)."
  type        = bool
  default     = true
}

variable "enable_dynamodb_gateway_endpoint" {
  description = "Create the DynamoDB gateway endpoint (free). Off unless a workload needs it."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = "Override the list of interface VPC endpoint services. Defaults in the module cover EKS workloads."
  type        = list(string)
  default = [
    "ecr.api",
    "ecr.dkr",
    "eks",
    "sts",
    "logs",
    "secretsmanager",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "elasticloadbalancing",
  ]
}
