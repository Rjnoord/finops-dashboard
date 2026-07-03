output "cur_bucket" {
  description = "Bucket receiving CUR data and Athena results"
  value       = aws_s3_bucket.cur.id
}

output "athena_workgroup" {
  description = "Workgroup all FinOps queries must run in"
  value       = aws_athena_workgroup.finops.name
}

output "glue_database" {
  description = "Glue database holding the CUR table"
  value       = aws_glue_catalog_database.cur.name
}

output "cur_table" {
  description = "Athena table name once the crawler has run"
  value       = "cur_${var.report_name}"
}

output "crawler_name" {
  description = "Run on demand with: aws glue start-crawler --name <this>"
  value       = aws_glue_crawler.cur.name
}
