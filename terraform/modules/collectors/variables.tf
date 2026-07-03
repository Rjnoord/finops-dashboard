variable "table_name" {
  description = "DynamoDB table for findings + daily cost aggregates"
  type        = string
  default     = "finops-data"
}

variable "required_tags" {
  description = "Tags every resource must carry for compliance"
  type        = list(string)
  default     = ["Owner", "Environment", "CostCenter"]
}

variable "cpu_idle_threshold" {
  description = "Average CPU %% below which a running instance counts as idle"
  type        = number
  default     = 5
}

variable "lookback_days" {
  description = "CPU averaging window for idle detection"
  type        = number
  default     = 7
}

variable "snapshot_age_days" {
  description = "Snapshots older than this with no AMI reference are stale"
  type        = number
  default     = 90
}

variable "schedule_expression" {
  description = "EventBridge schedule for all collectors"
  type        = string
  default     = "cron(30 8 * * ? *)" # 08:30 UTC, after the Glue crawler at 08:00
}
