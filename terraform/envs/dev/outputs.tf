output "plan_role_arn" {
  description = "Add to GitHub repo as variable AWS_PLAN_ROLE_ARN"
  value       = module.oidc_github.plan_role_arn
}

output "deploy_role_arn" {
  description = "Add to GitHub repo as variable AWS_DEPLOY_ROLE_ARN"
  value       = module.oidc_github.deploy_role_arn
}
