# =============================================================================
#  Network Module — Variables
#  ---------------------------------------------------------------------------
#  Design philosophy: opinionated where the answer is obvious (CIDR math,
#  3-tier topology), explicit where the trade-off matters (NAT mode, NACLs,
#  flow log destination). Every toggle defaults to the *secure* choice — a
#  caller has to *opt out* of hardening, never opt in.
#
#  Inspired by the org's `custome-vpc-module/VPC` (which exposes 233 inputs
#  for maximum flexibility). This module deliberately stays focused on a
#  single use case — a 3-tier VPC for EKS workloads — to keep the surface
#  area reviewable in one sitting.
# =============================================================================

# =============================================================================
#  CORE INPUTS
# =============================================================================

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

variable "tags" {
  description = <<-EOT
    Reserved for compatibility. The canonical tag set (Project, Environment,
    Owner, CostCenter, DataClassification, Repository, ManagedBy) is applied
    by the AWS provider's `default_tags` block at the environment level.
    The module only sets resource-specific tags (Name, Tier).
    Pass an empty map `{}` unless you need to add a one-off tag override.
  EOT
  type        = map(string)
  default     = {}
}

# =============================================================================
#  NAT GATEWAY MODE
#  ---------------------------------------------------------------------------
#  The two booleans below let the caller pick one of three modes:
#
#    Mode                       single_nat   per_az    Cost     HA
#    ─────────────────────────  ──────────   ──────    ────     ──
#    Single shared NAT (dev)    true         false     ~$32/mo  no
#    Per-AZ NAT (prod)          false        true      ~$32/AZ  yes
#    No NAT (private + endpts)  false        false     $0       n/a
#
#  Defaults are **per-AZ** — production-safe by default. Set
#  `single_nat_gateway = true` in dev tfvars to save money.
# =============================================================================

variable "single_nat_gateway" {
  description = "Use a single shared NAT Gateway in one AZ. Cheap (~$32/mo) but a single point of failure — only suitable for dev/staging."
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "Provision one NAT Gateway per AZ. Highly available and avoids cross-AZ data-transfer charges. Recommended for production."
  type        = bool
  default     = true
}

# =============================================================================
#  VPC FLOW LOGS
#  ---------------------------------------------------------------------------
#  Flow logs capture metadata for every IP packet flowing in/out of network
#  interfaces. Two destinations are supported:
#
#    cloud-watch-logs  → Better for ad-hoc investigation (CW Logs Insights),
#                        worse for cost at high volumes (~$0.50/GB ingested).
#    s3                → Far cheaper (~$0.023/GB stored) and works great with
#                        Athena for queries — preferred for long retention.
#
#  Production should typically enable flow logs to S3 with 90+ day retention.
# =============================================================================

variable "enable_flow_logs" {
  description = "Enable VPC flow logs. Strongly recommended in production for security/audit and incident response."
  type        = bool
  default     = true
}

variable "flow_logs_destination" {
  description = "Where to send flow logs. One of: cloud-watch-logs, s3."
  type        = string
  default     = "cloud-watch-logs"
  validation {
    condition     = contains(["cloud-watch-logs", "s3"], var.flow_logs_destination)
    error_message = "flow_logs_destination must be one of: cloud-watch-logs, s3."
  }
}

variable "flow_logs_retention_days" {
  description = "CloudWatch Logs retention period (days). Ignored when destination is S3."
  type        = number
  default     = 30
}

variable "flow_logs_s3_lifecycle_days" {
  description = "Days after which S3 flow log objects transition to Glacier IR. Ignored when destination is cloud-watch-logs."
  type        = number
  default     = 90
}

# =============================================================================
#  PER-TIER NETWORK ACLS (defense in depth)
#  ---------------------------------------------------------------------------
#  Security groups are stateful and operate at the ENI level — they're the
#  primary access control. NACLs are stateless and operate at the subnet
#  boundary. Why have both?
#
#    • Defense in depth — a misconfigured SG (e.g. 0.0.0.0/0 inbound) is
#      contained by the NACL.
#    • A caught-in-the-act control: NACLs deny entire CIDR ranges fast,
#      useful during incident response.
#    • The database NACL in particular hardens the "isolated tier" promise:
#      even if a private-tier workload is compromised, the NACL only allows
#      DB ports from private CIDRs.
#
#  Defaults below produce a reasonable hardened posture out of the box.
#  Override them by passing your own rule lists.
# =============================================================================

variable "enable_dedicated_nacls" {
  description = "Provision dedicated NACLs per tier. When false, all subnets share the default permissive NACL (allow-all). Recommended on for production."
  type        = bool
  default     = true
}

# Each rule object follows the AWS NACL rule contract. Lower rule_number
# values evaluate first; the first matching rule wins.
variable "public_inbound_acl_rules" {
  description = "Inbound NACL rules for the public tier. Defaults allow HTTP/HTTPS from anywhere + ephemeral return traffic."
  type = list(object({
    rule_number = number
    rule_action = string # allow | deny
    from_port   = number
    to_port     = number
    protocol    = string # tcp | udp | icmp | -1 (all)
    cidr_block  = string
  }))
  default = [
    { rule_number = 100, rule_action = "allow", from_port = 80, to_port = 80, protocol = "tcp", cidr_block = "0.0.0.0/0" },
    { rule_number = 110, rule_action = "allow", from_port = 443, to_port = 443, protocol = "tcp", cidr_block = "0.0.0.0/0" },
    # Ephemeral return ports for outbound-initiated traffic (NAT, package downloads, etc.).
    { rule_number = 120, rule_action = "allow", from_port = 1024, to_port = 65535, protocol = "tcp", cidr_block = "0.0.0.0/0" },
  ]
}

variable "public_outbound_acl_rules" {
  description = "Outbound NACL rules for the public tier. Default allows all egress (typical for ALB/NAT subnets)."
  type = list(object({
    rule_number = number
    rule_action = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_block  = string
  }))
  default = [
    { rule_number = 100, rule_action = "allow", from_port = 0, to_port = 0, protocol = "-1", cidr_block = "0.0.0.0/0" },
  ]
}

variable "private_inbound_acl_rules" {
  description = "Inbound NACL rules for the private tier. Default allows traffic only from inside the VPC + ephemeral return ports."
  type = list(object({
    rule_number = number
    rule_action = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_block  = string
  }))
  # NOTE: the literal "VPC_CIDR" placeholder below is replaced at runtime in
  # main.tf with var.vpc_cidr. We can't `${var.vpc_cidr}` here because
  # variable defaults can't reference other variables.
  default = [
    { rule_number = 100, rule_action = "allow", from_port = 0, to_port = 0, protocol = "-1", cidr_block = "VPC_CIDR" },
    { rule_number = 110, rule_action = "allow", from_port = 1024, to_port = 65535, protocol = "tcp", cidr_block = "0.0.0.0/0" },
  ]
}

variable "private_outbound_acl_rules" {
  description = "Outbound NACL rules for the private tier. Default allows all egress (workloads need to reach AWS APIs and the Internet via NAT)."
  type = list(object({
    rule_number = number
    rule_action = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_block  = string
  }))
  default = [
    { rule_number = 100, rule_action = "allow", from_port = 0, to_port = 0, protocol = "-1", cidr_block = "0.0.0.0/0" },
  ]
}

variable "database_inbound_acl_rules" {
  description = "Inbound NACL rules for the database tier. Default allows MySQL/Postgres/Redis ports from inside the VPC only — no Internet exposure."
  type = list(object({
    rule_number = number
    rule_action = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_block  = string
  }))
  default = [
    # Postgres
    { rule_number = 100, rule_action = "allow", from_port = 5432, to_port = 5432, protocol = "tcp", cidr_block = "VPC_CIDR" },
    # MySQL / Aurora
    { rule_number = 110, rule_action = "allow", from_port = 3306, to_port = 3306, protocol = "tcp", cidr_block = "VPC_CIDR" },
    # Redis
    { rule_number = 120, rule_action = "allow", from_port = 6379, to_port = 6379, protocol = "tcp", cidr_block = "VPC_CIDR" },
    # Ephemeral return for the rare egress (e.g. RDS to S3 for backups via VPC endpoint).
    { rule_number = 130, rule_action = "allow", from_port = 1024, to_port = 65535, protocol = "tcp", cidr_block = "VPC_CIDR" },
  ]
}

variable "database_outbound_acl_rules" {
  description = "Outbound NACL rules for the database tier. Default allows return traffic to the VPC only — the DB tier has no Internet route, so this is mostly belt-and-braces."
  type = list(object({
    rule_number = number
    rule_action = string
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_block  = string
  }))
  default = [
    { rule_number = 100, rule_action = "allow", from_port = 0, to_port = 0, protocol = "-1", cidr_block = "VPC_CIDR" },
  ]
}

# =============================================================================
#  VPC ENDPOINTS
#  ---------------------------------------------------------------------------
#  EKS workloads constantly hit AWS APIs: ECR (pull images), STS (IRSA token
#  exchange), CloudWatch Logs, Secrets Manager, the EKS API itself. Without
#  endpoints, every one of these calls leaves the VPC via the NAT Gateway
#  and pays NAT data-transfer charges (~$0.045/GB) plus the AWS API call.
#
#  Two endpoint types:
#    Gateway endpoints    — free, used for S3 and DynamoDB. Just a route
#                           entry; no ENI, no charge.
#    Interface endpoints  — ~$0.01/hr per AZ + $0.01/GB. Worth it the
#                           moment your NAT egress > ~$10/month for the
#                           same service.
#
#  The default service list below covers everything an EKS cluster needs.
# =============================================================================

variable "enable_vpc_endpoints" {
  description = "Provision VPC endpoints for AWS APIs. Saves NAT data-transfer cost and keeps API traffic on the AWS backbone (no Internet hop)."
  type        = bool
  default     = true
}

variable "interface_endpoint_services" {
  description = "List of AWS service names (without the regional prefix) for which to create interface endpoints. Defaults cover an EKS workload."
  type        = list(string)
  default = [
    "ecr.api",          # Pull image manifests
    "ecr.dkr",          # Pull image layers
    "eks",              # EKS control-plane API
    "sts",              # IRSA token exchange
    "logs",             # CloudWatch Logs
    "secretsmanager",   # External Secrets Operator targets
    "ssm",              # SSM Parameter Store, Session Manager
    "ssmmessages",      # Session Manager
    "ec2messages",      # SSM messaging
    "elasticloadbalancing", # AWS Load Balancer Controller
  ]
}

variable "enable_s3_gateway_endpoint" {
  description = "Create the S3 gateway endpoint. Free, and routes ECR layer pulls / log archives off the NAT path."
  type        = bool
  default     = true
}

variable "enable_dynamodb_gateway_endpoint" {
  description = "Create the DynamoDB gateway endpoint. Free. Off by default — flip on if any workload uses DynamoDB."
  type        = bool
  default     = false
}
