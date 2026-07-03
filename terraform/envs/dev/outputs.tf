output "plan_role_arn" {
  description = "Add to GitHub repo as variable AWS_PLAN_ROLE_ARN"
  value       = module.oidc_github.plan_role_arn
}

output "deploy_role_arn" {
  description = "Add to GitHub repo as variable AWS_DEPLOY_ROLE_ARN"
  value       = module.oidc_github.deploy_role_arn
}

output "athena_workgroup" {
  value = module.cur_athena.athena_workgroup
}

output "glue_database" {
  value = module.cur_athena.glue_database
}

output "cur_table" {
  description = "Table name once the crawler runs after first CUR delivery (~24h)"
  value       = module.cur_athena.cur_table
}

output "cur_crawler" {
  value = module.cur_athena.crawler_name
}

output "findings_table" {
  value = module.collectors.table_name
}

output "collector_functions" {
  value = module.collectors.function_names
}

output "alerts_topic_arn" {
  value = module.alerting.alerts_topic_arn
}

output "reporter_function" {
  value = module.alerting.reporter_function
}
