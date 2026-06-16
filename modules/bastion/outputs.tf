# =============================================================================
#  Bastion Module - Outputs
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID. Use with: aws ssm start-session --target <id>"
  value       = aws_instance.bastion.id
}

output "private_ip" {
  description = "Bastion private IP - reachable from inside the VPC."
  value       = aws_instance.bastion.private_ip
}

output "public_ip" {
  description = "Bastion public Elastic IP. Null when associate_public_ip = false."
  value       = try(aws_eip.bastion[0].public_ip, null)
}

output "public_dns" {
  description = "Bastion public DNS name. Null when no public IP."
  value       = try(aws_eip.bastion[0].public_dns, null)
}

output "security_group_id" {
  description = "Bastion SG ID - reference from RDS/EKS SGs to allow ingress from the bastion."
  value       = aws_security_group.bastion.id
}

output "iam_role_arn" {
  description = "Bastion IAM role ARN - reference if you need to extend permissions."
  value       = aws_iam_role.bastion.arn
}

output "ssm_start_session_command" {
  description = "Copy-paste shell command to start an SSM session with the bastion."
  value       = "aws ssm start-session --target ${aws_instance.bastion.id}"
}
