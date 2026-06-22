# =============================================================================
#  Budget Module - Variables
#  ---------------------------------------------------------------------------
#  Provisions a monthly cost budget filtered by Project tag, plus an SNS
#  topic + email subscription for alerts at configurable thresholds.
#
#  Designed to be called from each environment so dev and prod each get
#  their own budget and alerting.
# =============================================================================

variable "project_name" {
  description = "Project tag to filter spend by. Should match the Project tag on resources."
  type        = string
}

variable "environment" {
  description = "Environment name. Used in resource naming."
  type        = string
}

variable "monthly_limit_usd" {
  description = "Monthly budget in USD. Alerts fire as forecasted spend crosses thresholds."
  type        = number
}

variable "alert_thresholds_percent" {
  description = "Percentages of the monthly limit at which to alert. Default 50/80/100."
  type        = list(number)
  default     = [50, 80, 100]
}

variable "alert_emails" {
  description = "Email addresses to notify. AWS sends a confirmation email - subscribers must click to confirm."
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one alert_emails recipient is required."
  }
}
