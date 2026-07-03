variable "alert_email" {
  description = "Email address for billing alerts"
  type        = string
}

variable "threshold_usd" {
  description = "Alarm threshold in USD"
  type        = number
  default     = 10
}
