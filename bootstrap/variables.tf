# =============================================================================
#  Bootstrap — Inputs
# =============================================================================

variable "aws_region" {
  description = "AWS region in which to create the state bucket."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project identifier — used for tagging and bucket naming."
  type        = string
  default     = "ecommerce-eks"
}

variable "state_bucket_name" {
  description = "Globally-unique name of the S3 bucket that will hold remote Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "Bucket name must follow S3 naming rules: lowercase, 3-63 chars, no underscores."
  }
}
