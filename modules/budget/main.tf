# =============================================================================
#  Budget Module
#  ---------------------------------------------------------------------------
#  Three resources:
#    1. SNS topic              destination for budget alerts
#    2. SNS email subscription one per recipient
#    3. AWS Budget             monthly cost, scoped to Project tag, with one
#                              forecast-based notification per threshold
#
#  Implementation notes:
#    - aws_budgets_budget cost_filter uses TagKeyValue in the form
#      "Project$<value>". This captures every taggable resource with the
#      matching Project tag.
#    - Alerts are FORECASTED, not ACTUAL. They fire when AWS forecasts that
#      end-of-month spend will exceed the threshold - so you find out early.
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

resource "aws_sns_topic" "budget" {
  name = "${local.name_prefix}-budget-alerts"

  tags = {
    Name = "${local.name_prefix}-budget-alerts"
  }
}

# Allow the AWS Budgets service to publish to this topic.
data "aws_iam_policy_document" "budget_publish" {
  statement {
    sid    = "AllowBudgetsServicePublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.budget.arn]
  }
}

resource "aws_sns_topic_policy" "budget" {
  arn    = aws_sns_topic.budget.arn
  policy = data.aws_iam_policy_document.budget_publish.json
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.budget.arn
  protocol  = "email"
  endpoint  = each.value

  # Subscribers must confirm via the email AWS sends them. Until they do,
  # the subscription stays in PendingConfirmation - they receive no alerts.
}

resource "aws_budgets_budget" "monthly" {
  name              = "${local.name_prefix}-monthly"
  budget_type       = "COST"
  limit_amount      = tostring(var.monthly_limit_usd)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  cost_filter {
    name   = "TagKeyValue"
    values = ["Project$${var.project_name}"]
  }

  dynamic "notification" {
    for_each = toset(var.alert_thresholds_percent)
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "FORECASTED"
      subscriber_sns_topic_arns = [aws_sns_topic.budget.arn]
    }
  }
}
