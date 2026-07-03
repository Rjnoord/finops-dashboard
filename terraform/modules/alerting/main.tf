# Alerting & AI reporting — the "action" layer.
# Budgets fire at 80% actual / 100% forecast; Cost Anomaly Detection catches
# spend spikes budgets can't; a weekly Lambda turns the week's findings into
# an executive summary via Bedrock and emails it through SNS.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------- SNS: one topic for budgets, anomalies, and weekly reports ----------

resource "aws_sns_topic" "alerts" {
  name              = "finops-cost-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = { Project = "finops-dashboard" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Budgets and Cost Anomaly Detection publish as AWS service principals,
# so the topic policy must let them in (scoped to this account).
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "OwnerFullAccess"
    actions   = ["sns:*"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "BudgetsPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "AnomalyDetectionPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["costalerts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# ---------- AWS Budgets: monthly, 80% actual + 100% forecast ----------

resource "aws_budgets_budget" "monthly" {
  name         = "finops-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.alerts]
}

# ---------- Cost Anomaly Detection ----------

resource "aws_ce_anomaly_monitor" "services" {
  name              = "finops-service-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
  tags              = { Project = "finops-dashboard" }
}

resource "aws_ce_anomaly_subscription" "immediate" {
  name             = "finops-anomaly-alerts"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_impact_threshold_usd)]
    }
  }

  tags       = { Project = "finops-dashboard" }
  depends_on = [aws_sns_topic_policy.alerts]
}

# ---------- Weekly Bedrock summarizer Lambda ----------

data "archive_file" "reporter" {
  type        = "zip"
  source_dir  = "${path.module}/../../../src"
  output_path = "${path.module}/build/reporter.zip"
  excludes    = ["**/__pycache__/**"]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "reporter" {
  name               = "finops-reporter"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Project = "finops-dashboard" }
}

data "aws_iam_policy_document" "reporter" {
  statement {
    sid       = "ReadFindings"
    actions   = ["dynamodb:Query"]
    resources = [var.findings_table_arn]
  }

  # Scoped to Anthropic models only — the narrowest grant Bedrock offers
  # for foundation models and their cross-region inference profiles.
  statement {
    sid     = "InvokeClaude"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:*::foundation-model/anthropic.*",
      "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*.anthropic.*"
    ]
  }

  statement {
    sid       = "PublishReport"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.reporter.arn}:*"]
  }

  statement {
    sid       = "DeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.reporter_dlq.arn]
  }
}

resource "aws_iam_policy" "reporter" {
  name   = "finops-reporter"
  policy = data.aws_iam_policy_document.reporter.json
}

resource "aws_iam_role_policy_attachment" "reporter" {
  role       = aws_iam_role.reporter.name
  policy_arn = aws_iam_policy.reporter.arn
}

resource "aws_cloudwatch_log_group" "reporter" {
  #checkov:skip=CKV_AWS_158:Default CloudWatch Logs encryption is sufficient for lab logs
  #checkov:skip=CKV_AWS_338:14-day retention is deliberate — the report itself is delivered via SNS
  name              = "/aws/lambda/finops-reporter"
  retention_in_days = 14
  tags              = { Project = "finops-dashboard" }
}

resource "aws_sqs_queue" "reporter_dlq" {
  name                      = "finops-reporter-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = { Project = "finops-dashboard" }
}

resource "aws_lambda_function" "reporter" {
  #checkov:skip=CKV_AWS_117:Calls AWS APIs only; a VPC adds NAT cost without benefit
  #checkov:skip=CKV_AWS_272:Code signing is disproportionate for a single-dev lab
  #checkov:skip=CKV_AWS_173:Env vars hold ARNs and a model id — nothing secret
  #checkov:skip=CKV_AWS_50:X-Ray adds cost; structured logs cover observability at this scale
  #checkov:skip=CKV_AWS_115:Account concurrency quota is 10 (the AWS minimum unreserved pool); weekly EventBridge invocation makes runaway concurrency a non-risk
  function_name    = "finops-reporter"
  description      = "Weekly executive cost summary via Bedrock, delivered over SNS"
  role             = aws_iam_role.reporter.arn
  filename         = data.archive_file.reporter.output_path
  source_code_hash = data.archive_file.reporter.output_base64sha256
  handler          = "bedrock_reporter.summarizer.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 256

  dead_letter_config {
    target_arn = aws_sqs_queue.reporter_dlq.arn
  }

  environment {
    variables = {
      TABLE_NAME       = var.findings_table_name
      REPORT_TOPIC_ARN = aws_sns_topic.alerts.arn
      BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.reporter]
  tags       = { Project = "finops-dashboard" }
}

# Monday 13:00 UTC — after the weekend's daily collector runs have landed.
resource "aws_cloudwatch_event_rule" "weekly" {
  name                = "finops-weekly-report"
  schedule_expression = "cron(0 13 ? * MON *)"
  tags                = { Project = "finops-dashboard" }
}

resource "aws_cloudwatch_event_target" "reporter" {
  rule      = aws_cloudwatch_event_rule.weekly.name
  target_id = "reporter"
  arn       = aws_lambda_function.reporter.arn

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 3600
  }
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reporter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly.arn
}
