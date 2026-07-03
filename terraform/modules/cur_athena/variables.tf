variable "cur_bucket_name" {
  description = "Globally unique bucket for CUR delivery and Athena results"
  type        = string
}

variable "report_name" {
  description = "CUR report name (also drives the S3 path and Glue table name)"
  type        = string
  default     = "finops"
}

variable "cur_s3_prefix" {
  description = "S3 prefix CUR delivers under"
  type        = string
  default     = "cur"
}

variable "athena_results_prefix" {
  description = "S3 prefix for Athena query results (expired after 30 days)"
  type        = string
  default     = "athena-results"
}

variable "glue_database_name" {
  description = "Glue catalog database holding the CUR table"
  type        = string
  default     = "finops_cur"
}

variable "aws_region" {
  description = "Region the CUR bucket lives in"
  type        = string
}
