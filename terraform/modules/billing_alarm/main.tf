# Billing alarm — the first thing any lab account should have.
# NOTE: the EstimatedCharges metric only exists in us-east-1, so this
# module must be called with a us-east-1 provider (see envs/dev/main.tf).
# Also enable "Receive Billing Alerts" once in the console:
# Billing > Billing Preferences.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws]
    }
  }
}

resource "aws_sns_topic" "billing" {
  name = "finops-billing-alerts"
  tags = { Project = "finops-dashboard" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.billing.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "billing" {
  alarm_name          = "finops-lab-monthly-spend"
  alarm_description   = "Estimated charges exceeded the lab threshold - check for resources left running."
  namespace           = "AWS/Billing"
  metric_name         = "EstimatedCharges"
  statistic           = "Maximum"
  period              = 21600 # 6 hours
  evaluation_periods  = 1
  threshold           = var.threshold_usd
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    Currency = "USD"
  }

  alarm_actions = [aws_sns_topic.billing.arn]
  tags          = { Project = "finops-dashboard" }
}
