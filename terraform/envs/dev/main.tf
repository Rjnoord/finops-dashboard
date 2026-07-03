module "oidc_github" {
  source = "../../modules/oidc_github"

  github_org   = var.github_org
  github_repo  = var.github_repo
  state_bucket = var.state_bucket
  lock_table   = var.lock_table
  aws_region   = var.aws_region
}

module "billing_alarm" {
  source = "../../modules/billing_alarm"
  providers = {
    aws = aws.use1
  }

  alert_email   = var.alert_email
  threshold_usd = 10
}

module "cur_athena" {
  source = "../../modules/cur_athena"

  cur_bucket_name = var.cur_bucket_name
  aws_region      = var.aws_region
}

module "collectors" {
  source = "../../modules/collectors"
}

module "alerting" {
  source = "../../modules/alerting"

  alert_email         = var.alert_email
  findings_table_name = module.collectors.table_name
  findings_table_arn  = module.collectors.table_arn
}
