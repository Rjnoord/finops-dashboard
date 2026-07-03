# Collectors — four Python Lambdas on a daily EventBridge schedule, writing
# findings and cost aggregates into one on-demand DynamoDB table.
#
# Security posture per Lambda: its own IAM role with only the read APIs that
# collector calls (resource "*" only where AWS offers no resource-level
# control, e.g. ec2:Describe*), DynamoDB writes scoped to the one table,
# failures land in a per-function SQS DLQ.

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

locals {
  collectors = {
    idle_ec2 = {
      description = "Flags running EC2 instances under the CPU idle threshold"
      actions     = ["ec2:DescribeInstances", "cloudwatch:GetMetricData"]
    }
    orphaned_storage = {
      description = "Finds unattached EBS volumes, stale snapshots, idle Elastic IPs"
      actions = [
        "ec2:DescribeVolumes", "ec2:DescribeSnapshots",
        "ec2:DescribeImages", "ec2:DescribeAddresses"
      ]
    }
    tag_compliance = {
      description = "Computes required-tag compliance across the account"
      actions     = ["tag:GetResources"]
    }
    cost_aggregator = {
      description = "Stores yesterday's Cost Explorer spend by service"
      actions     = ["ce:GetCostAndUsage"]
    }
  }
}

# ---------- DynamoDB: findings + cost aggregates ----------

resource "aws_dynamodb_table" "data" {
  #checkov:skip=CKV_AWS_119:AWS-owned key is sufficient for lab cost metadata; a CMK adds monthly cost with no threat-model benefit
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Project = "finops-dashboard" }
}

# ---------- Shared code bundle ----------

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../../src"
  output_path = "${path.module}/build/collectors.zip"
  excludes    = ["**/__pycache__/**"]
}

# ---------- Per-collector resources ----------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "collector" {
  for_each           = local.collectors
  name               = "finops-collector-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = { Project = "finops-dashboard" }
}

data "aws_iam_policy_document" "collector" {
  for_each = local.collectors

  # The collector's read APIs. These AWS read actions do not support
  # resource-level permissions, so "*" is the narrowest possible grant.
  statement {
    sid       = "CollectorReads"
    actions   = each.value.actions
    resources = ["*"]
  }

  statement {
    sid       = "WriteFindings"
    actions   = ["dynamodb:PutItem", "dynamodb:BatchWriteItem"]
    resources = [aws_dynamodb_table.data.arn]
  }

  statement {
    sid       = "OwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.collector[each.key].arn}:*"]
  }

  statement {
    sid       = "DeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq[each.key].arn]
  }
}

resource "aws_iam_policy" "collector" {
  for_each = local.collectors
  name     = "finops-collector-${replace(each.key, "_", "-")}"
  policy   = data.aws_iam_policy_document.collector[each.key].json
}

resource "aws_iam_role_policy_attachment" "collector" {
  for_each   = local.collectors
  role       = aws_iam_role.collector[each.key].name
  policy_arn = aws_iam_policy.collector[each.key].arn
}

resource "aws_cloudwatch_log_group" "collector" {
  #checkov:skip=CKV_AWS_158:Default CloudWatch Logs encryption is sufficient for lab logs; KMS adds cost without benefit
  #checkov:skip=CKV_AWS_338:14-day retention is deliberate — findings live in DynamoDB, logs are only for debugging
  for_each          = local.collectors
  name              = "/aws/lambda/finops-${replace(each.key, "_", "-")}"
  retention_in_days = 14
  tags              = { Project = "finops-dashboard" }
}

resource "aws_sqs_queue" "dlq" {
  for_each                  = local.collectors
  name                      = "finops-${replace(each.key, "_", "-")}-dlq"
  message_retention_seconds = 1209600 # 14 days to notice and replay
  sqs_managed_sse_enabled   = true
  tags                      = { Project = "finops-dashboard" }
}

resource "aws_lambda_function" "collector" {
  #checkov:skip=CKV_AWS_117:Collectors call AWS APIs only; a VPC would add NAT cost and remove internet-free simplicity
  #checkov:skip=CKV_AWS_272:Code signing is disproportionate for a single-dev lab; CI provenance covers integrity
  #checkov:skip=CKV_AWS_173:Env vars hold table/tag names only — nothing secret to encrypt with a CMK
  #checkov:skip=CKV_AWS_50:X-Ray tracing adds cost; structured logs cover observability at this scale
  #checkov:skip=CKV_AWS_115:Account concurrency quota is 10 (the AWS minimum unreserved pool), so per-function reservations are impossible; daily EventBridge invocation makes runaway concurrency a non-risk
  for_each = local.collectors

  function_name    = "finops-${replace(each.key, "_", "-")}"
  description      = each.value.description
  role             = aws_iam_role.collector[each.key].arn
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  handler          = "collectors.${each.key}.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"] # ~20% cheaper per GB-second than x86
  timeout          = 120
  memory_size      = 256

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq[each.key].arn
  }

  environment {
    variables = {
      TABLE_NAME         = aws_dynamodb_table.data.name
      REQUIRED_TAGS      = join(",", var.required_tags)
      CPU_IDLE_THRESHOLD = tostring(var.cpu_idle_threshold)
      LOOKBACK_DAYS      = tostring(var.lookback_days)
      SNAPSHOT_AGE_DAYS  = tostring(var.snapshot_age_days)
    }
  }

  depends_on = [aws_cloudwatch_log_group.collector]
  tags       = { Project = "finops-dashboard" }
}

# ---------- Daily schedule ----------

resource "aws_cloudwatch_event_rule" "daily" {
  name                = "finops-collectors-daily"
  description         = "Runs every collector once a day, after the CUR/crawler window"
  schedule_expression = var.schedule_expression
  tags                = { Project = "finops-dashboard" }
}

resource "aws_cloudwatch_event_target" "collector" {
  for_each  = local.collectors
  rule      = aws_cloudwatch_event_rule.daily.name
  target_id = each.key
  arn       = aws_lambda_function.collector[each.key].arn

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 3600
  }
}

resource "aws_lambda_permission" "eventbridge" {
  for_each      = local.collectors
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.collector[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily.arn
}
