# =============================================================================
#  Bootstrap — Remote State Backend (S3-only, native locking)
#  ---------------------------------------------------------------------------
#  Provisions the single S3 bucket used to store Terraform remote state for
#  all environments (dev/staging/production) under different keys.
#
#  No DynamoDB lock table is created — Terraform 1.10+ uses a native
#  S3 lockfile (`<state-key>.tflock`) via `use_lockfile = true` in the
#  consumer backend configs.
#
#  Hardening applied:
#    • Bucket-level encryption (SSE-S3, swap to SSE-KMS for stronger control)
#    • Versioning ON (state history)
#    • All public access blocked
#    • TLS-only access enforced via bucket policy
#    • Object ownership set to bucket-owner-enforced (no ACLs)
# =============================================================================

# ── The state bucket itself ─────────────────────────────────────────────────
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  # Defense against `terraform destroy` accidentally wiping all state.
  # Set to `true` only when you intentionally want to tear the bucket down.
  force_destroy = false

  tags = {
    Name    = var.state_bucket_name
    Purpose = "terraform-remote-state"
  }
}

# ── Object ownership: deny ACLs, only bucket policy controls access ─────────
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ── Versioning: keeps every prior state file for rollback ───────────────────
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ── Server-side encryption ──────────────────────────────────────────────────
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ── Block all public access ─────────────────────────────────────────────────
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Bucket policy: deny non-TLS access ──────────────────────────────────────
resource "aws_s3_bucket_policy" "state_tls_only" {
  bucket = aws_s3_bucket.state.id

  # Public-access-block must be in place before adding a policy that references "*".
  depends_on = [aws_s3_bucket_public_access_block.state]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# ── Lifecycle policy: keep noncurrent versions for 90 days, then expire ────
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {} # apply to all objects

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
