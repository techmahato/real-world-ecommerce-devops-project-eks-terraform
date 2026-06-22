output "budget_name" {
  description = "Budget resource name."
  value       = aws_budgets_budget.monthly.name
}

output "sns_topic_arn" {
  description = "ARN of the budget alert SNS topic. Subscribe additional channels (Slack via chatbot, etc.) here."
  value       = aws_sns_topic.budget.arn
}
