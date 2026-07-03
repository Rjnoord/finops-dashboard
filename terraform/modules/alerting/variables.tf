variable "alert_email" {
  description = "Email subscribed to budget, anomaly, and weekly report notifications"
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget; alerts at 80% actual and 100% forecast"
  type        = number
  default     = 15
}

variable "anomaly_impact_threshold_usd" {
  description = "Minimum absolute anomaly impact before an alert fires"
  type        = number
  default     = 5
}

variable "findings_table_name" {
  description = "DynamoDB table the summarizer reads findings from"
  type        = string
}

variable "findings_table_arn" {
  description = "ARN of the findings table (for the reporter IAM policy)"
  type        = string
}

variable "bedrock_model_id" {
  description = "Bedrock model for the weekly summary (Converse API)"
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}
