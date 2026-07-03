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
