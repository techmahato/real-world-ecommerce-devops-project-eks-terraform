# =============================================================================
#  VPC Flow Logs
#  ---------------------------------------------------------------------------
#  Flow logs capture metadata for every IP packet (5-tuple, action, bytes,
#  packets) traversing an ENI. They are essential for:
#    • Security forensics — "did we see traffic from this attacker IP?"
#    • Incident response — reconstructing what happened during an outage.
#    • Cost analysis — which workloads talk to which AWS services?
#
#  Two destinations supported:
#
#    cloud-watch-logs   Best for ad-hoc investigation via CW Logs Insights.
#                       Cost: ~$0.50/GB ingested + storage. Gets pricey at
#                       a busy VPC's traffic volume.
#
#    s3                 Best for long retention + Athena-based analytics.
#                       Cost: ~$0.023/GB stored. With Glacier IR transition
#                       at 90 days, falls to ~$0.004/GB.
#
#  This module creates IAM, log group / bucket, and the flow log itself
#  conditionally based on `var.flow_logs_destination`.
# =============================================================================

locals {
  fl_enabled       = var.enable_flow_logs
  fl_to_cloudwatch = local.fl_enabled && var.flow_logs_destination == "cloud-watch-logs"
  fl_to_s3         = local.fl_enabled && var.flow_logs_destination == "s3"
}

# =============================================================================
#  CLOUDWATCH LOGS DESTINATION
# =============================================================================

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = local.fl_to_cloudwatch ? 1 : 0

  name              = "/aws/vpc/${local.name_prefix}/flow-logs"
  retention_in_days = var.flow_logs_retention_days

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-flow-logs"
  })
}

# IAM role used by the VPC Flow Logs service to write into CloudWatch.
resource "aws_iam_role" "flow_logs" {
  count = local.fl_to_cloudwatch ? 1 : 0

  name = "${local.name_prefix}-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = local.fl_to_cloudwatch ? 1 : 0

  name = "${local.name_prefix}-vpc-flow-logs"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs[0].arn}:*"
    }]
  })
}

# =============================================================================
#  S3 DESTINATION
#  ---------------------------------------------------------------------------
#  When destination is S3, we provision a hardened bucket (versioning,
#  encryption, public-access blocked, TLS-only) with a lifecycle rule that
#  transitions objects to Glacier IR after `flow_logs_s3_lifecycle_days`.
# =============================================================================

resource "aws_s3_bucket" "flow_logs" {
  count = local.fl_to_s3 ? 1 : 0

  bucket        = "${local.name_prefix}-vpc-flow-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-vpc-flow-logs"
  })
}

resource "aws_s3_bucket_ownership_controls" "flow_logs" {
  count = local.fl_to_s3 ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "flow_logs" {
  count = local.fl_to_s3 ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  count = local.fl_to_s3 ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  count = local.fl_to_s3 ? 1 : 0

  bucket                  = aws_s3_bucket.flow_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy:
#  1. AWSLogDeliveryWrite — flow-logs service can PutObject. The
#     SourceAccount/SourceArn conditions guard against the "confused
#     deputy" problem (another account's flow log delivery using our
#     bucket as a destination).
#  2. AWSLogDeliveryAclCheck — flow-logs service must GetBucketAcl
#     before writing.
#  3. DenyInsecureTransport — block non-TLS API calls to the bucket.
resource "aws_s3_bucket_policy" "flow_logs" {
  count = local.fl_to_s3 ? 1 : 0

  bucket     = aws_s3_bucket.flow_logs[0].id
  depends_on = [aws_s3_bucket_public_access_block.flow_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSLogDeliveryWrite"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.flow_logs[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      },
      {
        Sid       = "AWSLogDeliveryAclCheck"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.flow_logs[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.flow_logs[0].arn,
          "${aws_s3_bucket.flow_logs[0].arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  count = local.fl_to_s3 ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    id     = "transition-to-glacier-ir"
    status = "Enabled"

    # Empty prefix = apply to every object. The provider's v5 schema requires
    # an explicit `filter` block; using `prefix = ""` is the canonical way
    # to mean "everything" without filtering by tag/size.
    filter {
      prefix = ""
    }

    transition {
      days          = var.flow_logs_s3_lifecycle_days
      storage_class = "GLACIER_IR"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Look up the current account so we can build the correct bucket-policy
# resource ARN.
data "aws_caller_identity" "current" {}

# =============================================================================
#  THE FLOW LOG RESOURCE
#  ---------------------------------------------------------------------------
#  Exactly one of these is created when flow logs are enabled — the
#  destination_type and target are wired conditionally.
# =============================================================================

resource "aws_flow_log" "this" {
  count = local.fl_enabled ? 1 : 0

  vpc_id       = aws_vpc.this.id
  traffic_type = "ALL"

  log_destination_type = local.fl_to_s3 ? "s3" : "cloud-watch-logs"
  log_destination = local.fl_to_s3 ? (
    aws_s3_bucket.flow_logs[0].arn
    ) : (
    aws_cloudwatch_log_group.flow_logs[0].arn
  )

  # IAM role is only required for the CloudWatch path. For S3, AWS uses a
  # service-linked role under the hood — no caller-managed role needed.
  iam_role_arn = local.fl_to_cloudwatch ? aws_iam_role.flow_logs[0].arn : null

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-flow-log"
  })
}
