# ── VPC ─────────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID for this environment."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR for this environment."
  value       = module.network.vpc_cidr
}

# ── Public tier ─────────────────────────────────────────────────────────────
output "public_subnet_ids" {
  description = "Public subnet IDs (ALB / NAT / bastion)."
  value       = module.network.public_subnet_ids
}

# ── Private tier ────────────────────────────────────────────────────────────
output "private_subnet_ids" {
  description = "Private subnet IDs (EKS nodes / application workloads)."
  value       = module.network.private_subnet_ids
}

# ── Database tier ───────────────────────────────────────────────────────────
output "database_subnet_ids" {
  description = "Database subnet IDs (isolated tier — no Internet route)."
  value       = module.network.database_subnet_ids
}

output "db_subnet_group_name" {
  description = "DB subnet group name — pass to RDS modules."
  value       = module.network.db_subnet_group_name
}

output "elasticache_subnet_group_name" {
  description = "ElastiCache subnet group name — pass to Redis modules."
  value       = module.network.elasticache_subnet_group_name
}

# ── Bastion (only present when enable_bastion = true) ──────────────────────
output "bastion_instance_id" {
  description = "Bastion EC2 instance ID. Null when bastion is disabled."
  value       = try(module.bastion[0].instance_id, null)
}

output "bastion_public_ip" {
  description = "Bastion public IP for SSH. Null when bastion is disabled or has no public IP."
  value       = try(module.bastion[0].public_ip, null)
}

output "bastion_ssm_command" {
  description = "Copy-paste shell command to SSM into the bastion."
  value       = try(module.bastion[0].ssm_start_session_command, null)
}
