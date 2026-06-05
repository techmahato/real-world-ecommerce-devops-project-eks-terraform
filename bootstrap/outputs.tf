# =============================================================================
#  Bootstrap — Outputs
#  These values feed into each environment's `backend.hcl`.
# =============================================================================

output "state_bucket_id" {
  description = "Name of the S3 bucket holding remote Terraform state."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket holding remote Terraform state."
  value       = aws_s3_bucket.state.arn
}

output "aws_region" {
  description = "Region in which the state bucket lives."
  value       = var.aws_region
}

output "backend_hcl_snippet" {
  description = "Copy-paste this block into each environment's backend.hcl, replacing only `key`."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "environments/<ENV>/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
