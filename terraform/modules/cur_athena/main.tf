# CUR + Athena — the data foundation for every cost query in this project.
# Pipeline: AWS delivers the Cost & Usage Report (daily, Parquet) into S3;
# a Glue crawler catalogs it; Athena queries it through a workgroup with a
# per-query scan limit so a bad query can't run up the bill.
#
# NOTE: CUR report definitions only exist in us-east-1, and the first
# delivery takes up to 24 hours. The crawler will find nothing until then.
#
# NOTE: for the resource_tags_* columns to appear, activate the cost
# allocation tags (Owner, Environment, CostCenter) in the Billing console:
# Billing > Cost allocation tags.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------- S3: CUR delivery + Athena query results ----------

resource "aws_s3_bucket" "cur" {
  #checkov:skip=CKV_AWS_18:Single-account personal lab; access logging adds cost without value here
  #checkov:skip=CKV_AWS_144:Single-region lab; cross-region replication is disproportionate for rebuildable billing data
  #checkov:skip=CKV2_AWS_62:No downstream consumers for bucket event notifications
  #checkov:skip=CKV_AWS_21:CUR overwrites its report files daily; versioning would balloon storage for rebuildable data
  #checkov:skip=CKV_AWS_145:CUR delivery requires SSE-S3; billingreports.amazonaws.com cannot write with a customer KMS key
  bucket = var.cur_bucket_name

  tags = { Project = "finops-dashboard" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cur" {
  bucket = aws_s3_bucket.cur.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cur" {
  bucket                  = aws_s3_bucket.cur.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cur" {
  bucket = aws_s3_bucket.cur.id

  rule {
    id     = "expire-athena-results"
    status = "Enabled"
    filter {
      prefix = "${var.athena_results_prefix}/"
    }
    expiration {
      days = 30
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# CUR is delivered by the billingreports service principal; scope the grant
# to this account's report definitions so no other account can write here.
data "aws_iam_policy_document" "cur_delivery" {
  statement {
    sid       = "CurBucketChecks"
    actions   = ["s3:GetBucketAcl", "s3:GetBucketPolicy"]
    resources = [aws_s3_bucket.cur.arn]
    principals {
      type        = "Service"
      identifiers = ["billingreports.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cur:us-east-1:${data.aws_caller_identity.current.account_id}:definition/*"]
    }
  }

  statement {
    sid       = "CurObjectDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cur.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["billingreports.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "cur_delivery" {
  bucket = aws_s3_bucket.cur.id
  policy = data.aws_iam_policy_document.cur_delivery.json
}

# ---------- CUR report definition ----------

resource "aws_cur_report_definition" "finops" {
  report_name                = var.report_name
  time_unit                  = "DAILY"
  format                     = "Parquet"
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES"]
  s3_bucket                  = aws_s3_bucket.cur.id
  s3_prefix                  = var.cur_s3_prefix
  s3_region                  = var.aws_region
  additional_artifacts       = ["ATHENA"]
  report_versioning          = "OVERWRITE_REPORT"
  refresh_closed_reports     = true

  depends_on = [aws_s3_bucket_policy.cur_delivery]
}

# ---------- Glue: catalog the CUR data ----------

resource "aws_glue_catalog_database" "cur" {
  name = var.glue_database_name
}

data "aws_iam_policy_document" "crawler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crawler" {
  name               = "finops-glue-crawler"
  assume_role_policy = data.aws_iam_policy_document.crawler_assume.json
  tags               = { Project = "finops-dashboard" }
}

resource "aws_iam_role_policy_attachment" "crawler_service" {
  role       = aws_iam_role.crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "crawler_s3" {
  statement {
    sid       = "ReadCurData"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.cur.arn}/${var.cur_s3_prefix}/*"]
  }
  statement {
    sid       = "ListCurBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.cur.arn]
  }
}

resource "aws_iam_policy" "crawler_s3" {
  name   = "finops-glue-crawler-s3"
  policy = data.aws_iam_policy_document.crawler_s3.json
}

resource "aws_iam_role_policy_attachment" "crawler_s3" {
  role       = aws_iam_role.crawler.name
  policy_arn = aws_iam_policy.crawler_s3.arn
}

resource "aws_glue_crawler" "cur" {
  #checkov:skip=CKV_AWS_195:Lab-scope crawler over SSE-S3 encrypted billing data; a Glue security configuration (KMS) adds cost without benefit here
  name          = "finops-cur-crawler"
  database_name = aws_glue_catalog_database.cur.name
  role          = aws_iam_role.crawler.arn
  table_prefix  = "cur_"

  # CUR with the ATHENA artifact lands under {prefix}/{report}/{report}/
  s3_target {
    path = "s3://${aws_s3_bucket.cur.id}/${var.cur_s3_prefix}/${var.report_name}/${var.report_name}"
    exclusions = [
      "**.json",
      "**.yml",
      "**.sql",
      "**.csv",
      "**.gz",
      "**.zip",
      "**/cost_and_usage_data_status/**"
    ]
  }

  # Daily at 08:00 UTC — after AWS's overnight CUR delivery window.
  schedule = "cron(0 8 * * ? *)"

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = { Project = "finops-dashboard" }
}

# ---------- Athena: workgroup with cost guardrails ----------

resource "aws_athena_workgroup" "finops" {
  name = "finops"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # A runaway query cannot scan more than 1 GB (~$0.005). CUR data at
    # lab scale is a few MB, so this is generous headroom.
    bytes_scanned_cutoff_per_query = 1073741824

    result_configuration {
      output_location = "s3://${aws_s3_bucket.cur.id}/${var.athena_results_prefix}/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = { Project = "finops-dashboard" }
}

# ---------- Saved queries — the analyst's starting kit ----------

locals {
  cur_table = "cur_${var.report_name}"
}

resource "aws_athena_named_query" "spend_by_service_mtd" {
  name        = "finops-spend-by-service-mtd"
  description = "Month-to-date unblended spend grouped by service, highest first"
  workgroup   = aws_athena_workgroup.finops.name
  database    = aws_glue_catalog_database.cur.name
  query       = <<-SQL
    SELECT
      line_item_product_code AS service,
      ROUND(SUM(line_item_unblended_cost), 2) AS spend_usd
    FROM ${local.cur_table}
    WHERE line_item_usage_start_date >= date_trunc('month', current_date)
      AND line_item_line_item_type NOT IN ('Credit', 'Refund')
    GROUP BY 1
    ORDER BY 2 DESC;
  SQL
}

resource "aws_athena_named_query" "spend_by_cost_center" {
  name        = "finops-spend-by-cost-center"
  description = "MTD spend by CostCenter tag (requires the tag activated as a cost allocation tag)"
  workgroup   = aws_athena_workgroup.finops.name
  database    = aws_glue_catalog_database.cur.name
  query       = <<-SQL
    SELECT
      COALESCE(NULLIF(resource_tags_user_cost_center, ''), '(untagged)') AS cost_center,
      ROUND(SUM(line_item_unblended_cost), 2) AS spend_usd
    FROM ${local.cur_table}
    WHERE line_item_usage_start_date >= date_trunc('month', current_date)
      AND line_item_line_item_type NOT IN ('Credit', 'Refund')
    GROUP BY 1
    ORDER BY 2 DESC;
  SQL
}

resource "aws_athena_named_query" "untagged_spend" {
  name        = "finops-untagged-spend"
  description = "MTD spend on resources missing the CostCenter tag — the accountability gap"
  workgroup   = aws_athena_workgroup.finops.name
  database    = aws_glue_catalog_database.cur.name
  query       = <<-SQL
    SELECT
      line_item_product_code AS service,
      line_item_resource_id AS resource_id,
      ROUND(SUM(line_item_unblended_cost), 2) AS spend_usd
    FROM ${local.cur_table}
    WHERE line_item_usage_start_date >= date_trunc('month', current_date)
      AND line_item_line_item_type NOT IN ('Credit', 'Refund')
      AND line_item_resource_id <> ''
      AND (resource_tags_user_cost_center IS NULL OR resource_tags_user_cost_center = '')
    GROUP BY 1, 2
    HAVING SUM(line_item_unblended_cost) > 0
    ORDER BY 3 DESC
    LIMIT 50;
  SQL
}

resource "aws_athena_named_query" "daily_spend_trend" {
  name        = "finops-daily-spend-trend"
  description = "Daily total spend for the last 30 days — feed for the dashboard trend chart"
  workgroup   = aws_athena_workgroup.finops.name
  database    = aws_glue_catalog_database.cur.name
  query       = <<-SQL
    SELECT
      date_trunc('day', line_item_usage_start_date) AS usage_day,
      ROUND(SUM(line_item_unblended_cost), 2) AS spend_usd
    FROM ${local.cur_table}
    WHERE line_item_usage_start_date >= current_date - INTERVAL '30' DAY
      AND line_item_line_item_type NOT IN ('Credit', 'Refund')
    GROUP BY 1
    ORDER BY 1;
  SQL
}

resource "aws_athena_named_query" "top_resources" {
  name        = "finops-top-resources-mtd"
  description = "Top 25 individual resources by MTD spend — where the money actually goes"
  workgroup   = aws_athena_workgroup.finops.name
  database    = aws_glue_catalog_database.cur.name
  query       = <<-SQL
    SELECT
      line_item_resource_id AS resource_id,
      line_item_product_code AS service,
      ROUND(SUM(line_item_unblended_cost), 2) AS spend_usd
    FROM ${local.cur_table}
    WHERE line_item_usage_start_date >= date_trunc('month', current_date)
      AND line_item_line_item_type NOT IN ('Credit', 'Refund')
      AND line_item_resource_id <> ''
    GROUP BY 1, 2
    ORDER BY 3 DESC
    LIMIT 25;
  SQL
}
