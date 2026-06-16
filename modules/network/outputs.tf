# =============================================================================
#  Outputs
#  ---------------------------------------------------------------------------
#  Outputs are the module's public API. Downstream modules (EKS, RDS,
#  ElastiCache, ALB) reference them — so be conservative about renaming.
#  Each output here corresponds to something a downstream module needs.
# =============================================================================

# ── VPC ─────────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs. Length depends on NAT mode (0, 1, or one per AZ)."
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_mode" {
  description = "Resolved NAT mode in human-readable form. Useful for logging/asserts."
  value = (
    local.nat_count == 0 ? "none" :
    var.single_nat_gateway ? "single" :
    "per-az"
  )
}

# ── Public tier (ALB, NAT, bastion) ─────────────────────────────────────────
output "public_subnet_ids" {
  description = "Public subnet IDs (used for ALBs and NAT Gateways)."
  value       = aws_subnet.public[*].id
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDRs."
  value       = aws_subnet.public[*].cidr_block
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = aws_route_table.public.id
}

# ── Private tier (Apps, EKS nodes) ──────────────────────────────────────────
output "private_subnet_ids" {
  description = "Private subnet IDs (used for EKS nodes and application workloads)."
  value       = aws_subnet.private[*].id
}

output "private_subnet_cidrs" {
  description = "Private subnet CIDRs."
  value       = aws_subnet.private[*].cidr_block
}

output "private_route_table_ids" {
  description = "Private route table IDs (one per AZ)."
  value       = aws_route_table.private[*].id
}

# ── Database tier (RDS, ElastiCache — isolated) ─────────────────────────────
output "database_subnet_ids" {
  description = "Database subnet IDs (isolated tier — no Internet route)."
  value       = aws_subnet.database[*].id
}

output "database_subnet_cidrs" {
  description = "Database subnet CIDRs."
  value       = aws_subnet.database[*].cidr_block
}

output "database_route_table_id" {
  description = "Database route table ID (no default route — Internet-isolated)."
  value       = aws_route_table.database.id
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group — pass to RDS / Aurora / DocumentDB modules."
  value       = aws_db_subnet_group.this.name
}

output "elasticache_subnet_group_name" {
  description = "Name of the ElastiCache subnet group — pass to Redis / Memcached modules."
  value       = aws_elasticache_subnet_group.this.name
}

# ── Network ACLs ────────────────────────────────────────────────────────────
output "public_nacl_id" {
  description = "ID of the public-tier NACL. Empty when enable_dedicated_nacls = false."
  value       = try(aws_network_acl.public[0].id, null)
}

output "private_nacl_id" {
  description = "ID of the private-tier NACL. Empty when enable_dedicated_nacls = false."
  value       = try(aws_network_acl.private[0].id, null)
}

output "database_nacl_id" {
  description = "ID of the database-tier NACL. Empty when enable_dedicated_nacls = false."
  value       = try(aws_network_acl.database[0].id, null)
}

# ── VPC Endpoints ───────────────────────────────────────────────────────────
output "vpc_endpoints_security_group_id" {
  description = "ID of the SG attached to interface VPC endpoints. Empty when no interface endpoints exist."
  value       = try(aws_security_group.endpoints[0].id, null)
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint. Empty when disabled."
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "interface_endpoint_ids" {
  description = "Map of service name → interface endpoint ID. Empty when VPC endpoints are disabled."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

# ── Flow Logs ───────────────────────────────────────────────────────────────
output "flow_log_id" {
  description = "ID of the VPC flow log. Empty when disabled."
  value       = try(aws_flow_log.this[0].id, null)
}

output "flow_logs_s3_bucket" {
  description = "Name of the S3 bucket holding flow logs. Empty unless flow_logs_destination = \"s3\"."
  value       = try(aws_s3_bucket.flow_logs[0].bucket, null)
}

output "flow_logs_cloudwatch_log_group" {
  description = "Name of the CloudWatch log group holding flow logs. Empty unless flow_logs_destination = \"cloud-watch-logs\"."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].name, null)
}

# ── Locked-down defaults ────────────────────────────────────────────────────
# These exist to make it visible (in `terraform output`) that the default
# NACL and SG are managed and locked, not left as AWS-permissive defaults.
output "default_network_acl_id" {
  description = "ID of the VPC's default NACL — managed by this module and locked (no rules)."
  value       = aws_default_network_acl.this.id
}

output "default_security_group_id" {
  description = "ID of the VPC's default SG — managed by this module and locked (no rules)."
  value       = aws_default_security_group.this.id
}

# ── Misc ────────────────────────────────────────────────────────────────────
output "availability_zones" {
  description = "AZs used by this VPC."
  value       = var.availability_zones
}
