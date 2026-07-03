output "plan_role_arn" {
  description = "Role for PR workflows (terraform plan)"
  value       = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  description = "Role for main-branch workflows (terraform apply)"
  value       = aws_iam_role.deploy.arn
}
