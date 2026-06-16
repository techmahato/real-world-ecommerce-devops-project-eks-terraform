# =============================================================================
#  Production Environment — Variable Declarations
#  ---------------------------------------------------------------------------
#  Defaults favor production: per-AZ NAT (HA), flow logs to S3 (cheap long
#  retention), all hardening on.
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

# ── NAT mode — prod default: per-AZ for HA ──────────────────────────────────
variable "single_nat_gateway" {
  description = "Use a single shared NAT Gateway. Off in prod (HA matters)."
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "One NAT per AZ. On in prod for HA + avoiding cross-AZ data charges."
  type        = bool
  default     = true
}

# ── Flow logs ───────────────────────────────────────────────────────────────
variable "enable_flow_logs" {
  description = "Enable VPC flow logs."
  type        = bool
  default     = true
}

variable "flow_logs_destination" {
  description = "Destination for flow logs: cloud-watch-logs or s3. S3 is cheaper for long retention."
  type        = string
  default     = "s3"
}

variable "flow_logs_retention_days" {
  description = "CloudWatch retention. Ignored when destination is s3."
  type        = number
  default     = 90
}

variable "flow_logs_s3_lifecycle_days" {
  description = "Days before flow log objects transition to Glacier IR."
  type        = number
  default     = 90
}

# ── Hardening toggles ───────────────────────────────────────────────────────
variable "enable_dedicated_nacls" {
  description = "Per-tier NACLs."
  type        = bool
  default     = true
}

# ── VPC endpoints ───────────────────────────────────────────────────────────
variable "enable_vpc_endpoints" {
  description = "Provision VPC endpoints."
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
  description = "Override the list of interface VPC endpoint services."
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
