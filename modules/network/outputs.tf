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
  description = "List of NAT Gateway IDs (one per AZ in non-dev, single in dev)."
  value       = aws_nat_gateway.this[*].id
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

# ── Availability Zones ──────────────────────────────────────────────────────
output "availability_zones" {
  description = "AZs used by this VPC."
  value       = var.availability_zones
}
